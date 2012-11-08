# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::sles;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use Storable qw(dclone);
use Sys::Syslog;
use File::Temp qw/tempdir/;
use xCAT::Table;
use xCAT::Utils;
use xCAT::TableUtils;
use xCAT::NetworkUtils;
use xCAT::SvrUtils;
use xCAT::MsgUtils;
use Data::Dumper;
use Getopt::Long;
Getopt::Long::Configure("bundling");
Getopt::Long::Configure("pass_through");
use File::Path;
use File::Copy;
use File::Temp qw/mkdtemp/;
my $httpmethod = "http";
my $httpport = "80";
use File::Find;
use File::Basename;

use Socket;

use strict;
my @cpiopid;

sub handled_commands
{
    return {
            copycd    => "sles",
            mknetboot => "nodetype:os=(sles.*)|(suse.*)",
            mkinstall => "nodetype:os=(sles.*)|(suse.*)",
            mkstatelite => "nodetype:os=(sles.*)"
            };
}

sub mknetboot
{
    my $req      = shift;
    my $callback = shift;
    my $doreq    = shift;

    my $statelite = 0;
    if($req->{command}->[0] =~ 'mkstatelite') {
        $statelite = "true";
    }

    my $globaltftpdir  = "/tftpboot";
    my $nodes    = @{$req->{node}};
    my @nodes    = @{$req->{node}};
    my $ostab    = xCAT::Table->new('nodetype');
    #my $sitetab  = xCAT::Table->new('site');
    my $linuximagetab;
    my $pkgdir;
    my $osimagetab;
    my $installroot;
    $installroot = "/install";

    my $xcatdport = "3001";

    #if ($sitetab)
    #{
        #(my $ref) = $sitetab->getAttribs({key => 'installdir'}, 'value');
        my @entries =  xCAT::TableUtils->get_site_attribute("installdir");
        my $t_entry = $entries[0];
        if ( defined($t_entry) ) {
            $installroot = $t_entry;
        }
        #($ref) = $sitetab->getAttribs({key => 'xcatdport'}, 'value');
        @entries =  xCAT::TableUtils->get_site_attribute("xcatdport");
        $t_entry = $entries[0];
        if ( defined($t_entry) ) {
            $xcatdport = $t_entry;
        }
    #}

    my $ntents = $ostab->getNodesAttribs($req->{node}, ['os', 'arch', 'profile', 'provmethod']);
    my %img_hash=();

    my $statetab;
    my $stateHash;
    if ($statelite) {
        $statetab = xCAT::Table->new('statelite', -create=>1);
        $stateHash = $statetab->getNodesAttribs(\@nodes, ['statemnt']);
    }

    # TODO: following the redhat change, get the necessary attributes before the next foreach
    # get the mac addresses for all the nodes
    my $mactab = xCAT::Table->new('mac');
    my $machash = $mactab->getNodesAttribs(\@nodes, ['interface', 'mac']);

    my $restab = xCAT::Table->new('noderes');
    my $reshash = $restab->getNodesAttribs(\@nodes, ['primarynic', 'tftpserver', 'tftpdir', 'xcatmaster', 'nfsserver', 'nfsdir', 'installnic']);

    my %donetftp=();
    foreach my $node (@nodes)
    {
        my $osver;
        my $arch;
        my $profile;
        my $provmethod;
        my $rootimgdir;
        my $nodebootif; # nodebootif will be used if noderes.installnic is not set
        my $dump;  #for kdump
        my $crashkernelsize;
        my $rootfstype;
	
	    my $ent= $ntents->{$node}->[0];
        if ($ent and $ent->{provmethod} and ($ent->{provmethod} ne 'install') and ($ent->{provmethod} ne 'netboot') and ($ent->{provmethod} ne 'statelite')) {
	        my $imagename=$ent->{provmethod};
	        #print "imagename=$imagename\n";
	        if (!exists($img_hash{$imagename})) {
		        if (!$osimagetab) {
		            $osimagetab=xCAT::Table->new('osimage', -create=>1);
		        }
		        (my $ref) = $osimagetab->getAttribs({imagename => $imagename}, 'osvers', 'osarch', 'profile', 'rootfstype', 'provmethod');
		        if ($ref) {
		            $img_hash{$imagename}->{osver}=$ref->{'osvers'};
		            $img_hash{$imagename}->{osarch}=$ref->{'osarch'};
		            $img_hash{$imagename}->{profile}=$ref->{'profile'};
                    $img_hash{$imagename}->{rootfstype}=$ref->{'rootfstype'};
		            $img_hash{$imagename}->{provmethod}=$ref->{'provmethod'};
		            if (!$linuximagetab) {
			            $linuximagetab=xCAT::Table->new('linuximage', -create=>1);
		            }
		            (my $ref1) = $linuximagetab->getAttribs({imagename => $imagename}, 'rootimgdir', 'nodebootif', 'dump', 'crashkernelsize');
		            if (($ref1) && ($ref1->{'rootimgdir'})) {
			            $img_hash{$imagename}->{rootimgdir}=$ref1->{'rootimgdir'};
		            }
                    if (($ref1) && ($ref1->{'nodebootif'})) {
                        $img_hash{$imagename}->{nodebootif} = $ref1->{'nodebootif'};
                    }
		 			if (($ref1) && ($ref1->{'dump'})){
						$img_hash{$imagename}->{dump} = $ref1->{'dump'};
					}
					if (($ref1) && ($ref1->{'crashkernelsize'})) {
                        $img_hash{$imagename}->{crashkernelsize} = $ref1->{'crashkernelsize'};
                    }
		        } else {
		            $callback->(
			            {error     => ["The os image $imagename does not exists on the osimage table for $node"],
			            errorcode => [1]});
		            next;
		        }
	        }
	        my $ph=$img_hash{$imagename};
	        $osver = $ph->{osver};
	        $arch  = $ph->{osarch};
	        $profile = $ph->{profile};
            $rootfstype = $ph->{rootfstype};
            $nodebootif = $ph->{nodebootif};
	    $provmethod = $ph->{provmethod};
			$dump = $ph->{dump};
			$crashkernelsize = $ph->{crashkernelsize};
	
	        $rootimgdir = $ph->{rootimgdir};
	        unless ($rootimgdir) {
		        $rootimgdir = "$installroot/netboot/$osver/$arch/$profile";
	        }
	    }
	    else {
	        $osver = $ent->{os};
	        $arch    = $ent->{arch};
	        $profile = $ent->{profile};
            $rootfstype = "nfs";    # TODO: try to get it from the option or table
            my $imgname;
            if ($statelite) {
                $imgname = "$osver-$arch-statelite-$profile";
            } else {
                $imgname = "$osver-$arch-netboot-$profile";
            }

            if (! $osimagetab) {
                $osimagetab = xCAT::Table->new('osimage');
            }

            if ($osimagetab) {
                my ($ref1) = $osimagetab->getAttribs({imagename => $imgname}, 'rootfstype');
                if (($ref1) && ($ref1->{'rootfstype'})) {
                    $rootfstype = $ref1->{'rootfstype'};
                }
            } else {
                $callback->(
                    { error => [ qq{Cannot find the linux image called "$osver-$arch-$provmethod-$profile", maybe you need to use the "nodeset <nr> osimage=<osimage name>" command to set the boot state} ],
                    errorcode => [1]}
                );
            }

			#get the dump path and kernel crash memory side for kdump on sles
			if (!$linuximagetab){
				$linuximagetab = xCAT::Table->new('linuximage');
			}
			if ($linuximagetab){
				(my $ref1) = $linuximagetab->getAttribs({imagename => $imgname}, 'dump', 'crashkernelsize');
				if ($ref1 && $ref1->{'dump'}){
					$dump = $ref1->{'dump'};
				}
				if ($ref1 and $ref1->{'crashkernelsize'}){
					$crashkernelsize = $ref1->{'crashkernelsize'};
				}
			}
			else{
				$callback->(
                    { error => [qq{ Cannot find the linux image called "$osver-$arch-$imgname-$profile", maybe you need to use the "nodeset <nr> osimage=<your_image_name>" command to set the boot state}],
                    errorcode => [1] }
                );
			}

	        $rootimgdir="$installroot/netboot/$osver/$arch/$profile";
	    }

	    unless ($osver and $arch and $profile)
	    {
	        $callback->(
		    {
		        error     => ["Insufficient nodetype entry or osimage entry for $node"],
		        errorcode => [1]
		    }
		    );
	        next;
	    }

        #print"osvr=$osver, arch=$arch, profile=$profile, imgdir=$rootimgdir\n";
	    my $platform;
        if ($osver =~ /sles.*/)
        {
            $platform = "sles";
            # TODO: should get the $pkgdir value from the linuximage table
            $pkgdir = "$installroot/$osver/$arch";
        }elsif($osver =~ /suse.*/){
            $platform = "sles";
	    }

        my $suffix  = 'gz';       
        if (-r "$rootimgdir/rootimg.sfs")
        {
            $suffix = 'sfs';
        }

        if ($statelite) {
            unless ( -r "$rootimgdir/kernel") {
                $callback->({
                    error=>[qq{Did you run "genimage" before running "liteimg"? kernel cannot be found}],
                    errorcode => [1]
                });
                next;
            } 
            if ( $rootfstype eq "ramdisk" and ! -r "$rootimgdir/rootimg-statelite.gz" ) {
                $callback->({
                    error=>[qq{No packed rootimage for the platform $osver, arch $arch and profile $profile, please run liteimg to create it}],
                    errorcode=>[1]
                });
                next;
            }

	    if (!-r "$rootimgdir/initrd-statelite.gz") {
                if (! -r "$rootimgdir/initrd.gz") {
                    $callback->({
                        error=>[qq{Did you run "genimage" before running "liteimg"? initrd.gz or initrd-statelite.gz cannot be found}],
                        errorcode=>[1]
				});
                    next;
                }
		else {
		    copy("$rootimgdir/initrd.gz", "$rootimgdir/initrd-statelite.gz");
                }
	    }
	    
        } else {
            unless ( -r "$rootimgdir/kernel") {
                $callback->({
                    error=>[qq{Did you run "genimage" before running "packimage"? kernel cannot be found}],
                    errorcode=>[1]
			    });
                next;
	    }
	    if (!-r "$rootimgdir/initrd-stateless.gz") {
                if (! -r "$rootimgdir/initrd.gz") {
                    $callback->({
                        error=>[qq{Did you run "genimage" before running "packimage"? initrd.gz or initrd-stateless.gz cannot be found}],
                        errorcode=>[1]
				});
                    next;
                }
		else {
		    copy("$rootimgdir/initrd.gz", "$rootimgdir/initrd-stateless.gz");
                }
            }
	    
            unless ( -r "$rootimgdir/rootimg.gz" or -r "$rootimgdir/rootimg.sfs" ) {
                $callback->({
                    error=>[qq{No packed image for platform $osver, architecture $arch, and profile $profile, please run packimage before nodeset}],
                    errorcode=>[1]
                });
                next;
            }
        }
        my $tftpdir;
 	if ($reshash->{$node}->[0] and $reshash->{$node}->[0]->{tftpdir}) {
	   $tftpdir = $reshash->{$node}->[0]->{tftpdir};
        } else {
	   $tftpdir = $globaltftpdir;
        }


        mkpath("/$tftpdir/xcat/netboot/$osver/$arch/$profile/");

        #TODO: only copy if newer...
        unless ($donetftp{$osver,$arch,$profile,$tftpdir}) {
            copy("$rootimgdir/kernel", "/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
            if ($statelite) {
                copy("$rootimgdir/initrd-statelite.gz", "/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
            } else {
                copy("$rootimgdir/initrd-stateless.gz", "/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
            }
            $donetftp{$osver,$arch,$profile,$tftpdir} = 1;
        }

        if ($statelite) {
            unless ( -r "/$tftpdir/xcat/netboot/$osver/$arch/$profile/kernel" 
                    and -r "/$tftpdir/xcat/netboot/$osver/$arch/$profile/initrd-statelite.gz") {
                $callback->({
                    error=>[qq{copying to /$tftpdir/xcat/netboot/$osver/$arch/$profile failed}],
                    errorcode=>[1]
                });
                next;
            }
        } else {
            unless ( -r "/$tftpdir/xcat/netboot/$osver/$arch/$profile/kernel" 
                    and -r "/$tftpdir/xcat/netboot/$osver/$arch/$profile/initrd-stateless.gz") {
                $callback->({
                    error=>[qq{copying to /$tftpdir/xcat/netboot/$osver/$arch/$profile failed}],
                    errorcode=>[1]
                });
                next;
            }
        }

        # TODO: move the table operations out of the foreach loop
        my $bptab  = xCAT::Table->new('bootparams',-create=>1);
        my $hmtab  = xCAT::Table->new('nodehm');
        my $sent   =
          $hmtab->getNodeAttribs($node,
                                 ['serialport', 'serialspeed', 'serialflow']);

        # determine image server, if tftpserver use it, else use xcatmaster
        # last resort use self
        my $imgsrv;
        my $ient;
        my $xcatmaster;

        $ient = $restab->getNodeAttribs($node, ['xcatmaster']);
        if ($ient and $ient->{xcatmaster})
        {
            $xcatmaster = $ient->{xcatmaster};
        } else {
            $xcatmaster = '!myipfn!'; #allow service nodes to dynamically nominate themselves as a good contact point, this is of limited use in the event that xcat is not the dhcp/tftp server
        }

        $ient = $restab->getNodeAttribs($node, ['tftpserver']);
        if ($ient and $ient->{tftpserver})
        {
            $imgsrv = $ient->{tftpserver};
        }
        else
        {
        #    $ient = $restab->getNodeAttribs($node, ['xcatmaster']);
        #    if ($ient and $ient->{xcatmaster})
        #    {
        #        $imgsrv = $ient->{xcatmaster};
        #    }
        #    else
        #    {
        #        # master removed, does not work for servicenode pools
        #        #$ient = $sitetab->getAttribs({key => master}, value);
        #        #if ($ient and $ient->{value})
        #        #{
        #         #   $imgsrv = $ient->{value};
        #        #}
        #        #else
        #        #{
        #        $imgsrv = '!myipfn!';
        #        #}
        #    }
            $imgsrv = $xcatmaster;
        }
        unless ($imgsrv)
        {
            $callback->(
                {
                 error => [
                     "Unable to determine or reasonably guess the image server for $node"
                 ],
                 errorcode => [1]
                }
                );
            next;
        }
        my $kcmdline;
        if ($statelite) 
        {
            if($rootfstype ne "ramdisk") {
                # get entry for nfs root if it exists;
                # have to get nfssvr, nfsdir and xcatmaster from noderes table
                my $nfssrv = $imgsrv;
                my $nfsdir = $rootimgdir;
                
                if ($restab) {
                    my $resHash = $restab->getNodeAttribs($node, ['nfsserver', 'nfsdir']);
                    if($resHash and $resHash->{nfsserver}) {
                        $nfssrv = $resHash->{nfsserver};
                    }
                    if($resHash and $resHash->{nfsdir} ne '') {
                        $nfsdir = $resHash->{nfsdir} . "/netboot/$osver/$arch/$profile";
                    }
                }
                $kcmdline = 
                    "NFSROOT=$nfssrv:$nfsdir STATEMNT=";
            } else {
                $kcmdline =
                    "imgurl=$httpmethod://$imgsrv/$rootimgdir/rootimg-statelite.gz STATEMNT=";
            }
            # add support for subVars in the value of "statemnt"
            my $statemnt="";
            if (exists($stateHash->{$node})) {
                $statemnt = $stateHash->{$node}->[0]->{statemnt};
                if (grep /\$/, $statemnt) {
                    my ($server, $dir) = split(/:/, $statemnt);
                    
                    #if server is blank, then its the directory
                    unless($dir) {
                        $dir = $server;
                        $server = '';
                    }
                    if(grep /\$|#CMD/, $dir) {
                        $dir = xCAT::SvrUtils->subVars($dir, $node, 'dir', $callback);
                        $dir =~ s/\/\//\//g;
                    }
                    if($server) {
                        $server = xCAT::SvrUtils->subVars($server, $node, 'server', $callback);
                    }
                    $statemnt = $server . ":" . $dir;
                }
            }
            $kcmdline .= $statemnt . " ";
            # get "xcatmaster" value from the "noderes" table
            
            if($rootfstype ne "ramdisk") {
                #BEGIN service node 
                my $isSV = xCAT::Utils->isServiceNode();
                my $res = xCAT::Utils->runcmd("hostname", 0);
                my $sip = xCAT::NetworkUtils->getipaddr($res);  # this is the IP of service node
                if($isSV and (($xcatmaster eq $sip) or ($xcatmaster eq $res))) {
                    # if the NFS directory in litetree is on the service node, 
                    # and it is not exported, then it will be mounted automatically 
                    xCAT::SvrUtils->setupNFSTree($node, $sip, $callback);
                    # then, export the statemnt directory if it is on the service node
                    if($statemnt) {
                        xCAT::SvrUtils->setupStatemnt($sip, $statemnt, $callback);
                    }
                }
                #END sevice node 
            }
        }
        else
        {
            $kcmdline =
              "imgurl=$httpmethod://$imgsrv/$rootimgdir/rootimg.$suffix ";
        }
        $kcmdline .= "XCAT=$xcatmaster:$xcatdport quiet ";

        # add the kernel-booting parameter: netdev=<eth0>, or BOOTIF=<mac>
        my $netdev = "";
        my $mac = $machash->{$node}->[0]->{mac};

        if ($reshash->{$node}->[0] and $reshash->{$node}->[0]->{installnic} and ($reshash->{$node}->[0]->{installnic} ne "mac")) {
                $kcmdline .= "netdev=" . $reshash->{$node}->[0]->{installnic} . " ";
        } elsif ($nodebootif) {
            $kcmdline .=  "netdev=" . $nodebootif . " ";
        } elsif ($reshash->{$node}->[0] and $reshash->{$node}->[0]->{primarynic} and ($reshash->{$node}->[0]->{primarynic} ne "mac")) {
            $kcmdline .= "netdev=" . $reshash->{$node}->[0]->{primarynic} . " ";
        } else {
            if ($arch =~ /x86/) {
                #do nothing, we'll let pxe/xnba work their magic
            } elsif ($mac) {
                $kcmdline .=  "BOOTIF=" . $mac . " ";
            } else {
                $callback->({
                    error=>[qq{"cannot get the mac address for $node in mac table"}],
                    errorcode=>[1]
                });
            }
        }


        if (defined $sent->{serialport})
        {

            #my $sent = $hmtab->getNodeAttribs($node,['serialspeed','serialflow']);
            unless ($sent->{serialspeed})
            {
                $callback->(
                    {
                     error => [
                         "serialport defined, but no serialspeed for $node in nodehm table"
                     ],
                     errorcode => [1]
                    }
                    );
                next;
            }
            $kcmdline .=
              "console=tty0 console=ttyS" . $sent->{serialport} . "," . $sent->{serialspeed};
            if ($sent->{serialflow} =~ /(hard|tcs|ctsrts)/)
            {
                $kcmdline .= "n8r";
            }
        }

		#create the kcmd for node to support kdump
		if ($dump){
			if ($crashkernelsize){
				$kcmdline .= " crashkernel=$crashkernelsize dump=$dump ";
			}
			else{
				# for ppc64, the crashkernel paramter should be "128M@32M", otherwise, some kernel crashes will be met
				if ($arch eq "ppc64"){
					$kcmdline .= " crashkernel=256M\@64M dump=$dump ";
				}
				if ($arch =~ /86/){
					$kcmdline .= " crashkernel=128M dump=$dump ";
				}
			}
		}

        my $initrdstr = "xcat/netboot/$osver/$arch/$profile/initrd-stateless.gz";
        $initrdstr = "xcat/netboot/$osver/$arch/$profile/initrd-statelite.gz" if ($statelite);

		if($statelite)
		{
		    my $statelitetb = xCAT::Table->new('statelite');
                    my $mntopts = $statelitetb->getNodeAttribs($node, ['mntopts']);
		    
		    my $mntoptions = $mntopts->{'mntopts'};
		    if(defined($mntoptions))
		    {
				$kcmdline .= "MNTOPTS=\'$mntoptions\'";
		    }			
		}
        $bptab->setNodeAttribs(
                      $node,
                      {
                       kernel => "xcat/netboot/$osver/$arch/$profile/kernel",
                       initrd => $initrdstr,
                       kcmdline => $kcmdline
                      }
                      );
    }
}

sub process_request
{
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $distname = undef;
    my $arch     = undef;
    my $path     = undef;
    if ($::XCATSITEVALS{"httpmethod"}) { $httpmethod = $::XCATSITEVALS{"httpmethod"}; }
    if ($::XCATSITEVALS{"httpport"}) { $httpport = $::XCATSITEVALS{"httpport"}; }
    if ($request->{command}->[0] eq 'copycd')
    {
        return copycd($request, $callback, $doreq);
    }
    elsif ($request->{command}->[0] eq 'mkinstall')
    {
        return mkinstall($request, $callback, $doreq);
    }
    elsif ($request->{command}->[0] eq 'mknetboot' or
    $request->{command}->[0] eq 'mkstatelite')
    {
        return mknetboot($request, $callback, $doreq);
    }
}

sub mkinstall
{
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $globaltftpdir = xCAT::TableUtils->getTftpDir();

    my @nodes    = @{$request->{node}};
    my $node;
    my $ostab = xCAT::Table->new('nodetype');
    #my $sitetab  = xCAT::Table->new('site');
    my $linuximagetab;
    my $osimagetab;

    my $ntents = $ostab->getNodesAttribs($request->{node}, ['os', 'arch', 'profile', 'provmethod']);
    my %img_hash=();
    my $installroot;
    $installroot = "/install";
            my $restab = xCAT::Table->new('noderes');
            my $bptab = xCAT::Table->new('bootparams',-create=>1);
            my $hmtab  = xCAT::Table->new('nodehm');
            my $resents    = 
              $restab->getNodesAttribs(
                                      \@nodes,
                                      [
                                       'nfsserver', 'tftpdir','xcatmaster',
                                       'primarynic', 'installnic'
                                      ]
                                      );
            my $hments =
              $hmtab->getNodesAttribs(\@nodes, ['serialport', 'serialspeed', 'serialflow']);

    #if ($sitetab)
    #{
        #(my $ref) = $sitetab->getAttribs({key => 'installdir'}, 'value');
        my @entries =  xCAT::TableUtils->get_site_attribute("installdir");
        my $t_entry = $entries[0];
        if ( defined($t_entry) ) {
            $installroot = $t_entry;
        }
    #}

    my %doneimgs;
    require xCAT::Template; #only used here, load so memory can be COWed
    # Define a variable for driver update list
    my @dd_drivers;
    foreach $node (@nodes)
    {
        my $os;
        my $arch;
        my $profile;
        my $tmplfile;
        my $pkgdir;
	my $pkglistfile;
        my $osinst;
        my $ent = $ntents->{$node}->[0];
	my $plat = "";
        my $tftpdir;
        my $partfile;
        my $netdrivers;
        my $driverupdatesrc;
 	if ($resents->{$node} and $resents->{$node}->[0]->{tftpdir}) {
	   $tftpdir = $resents->{$node}->[0]->{tftpdir};
        } else {
	   $tftpdir = $globaltftpdir;
        }

        if ($ent and $ent->{provmethod} and ($ent->{provmethod} ne 'install') and ($ent->{provmethod} ne 'netboot') and ($ent->{provmethod} ne 'statelite')) {
	    my $imagename=$ent->{provmethod};
	    #print "imagename=$imagename\n";
	    if (!exists($img_hash{$imagename})) {
		if (!$osimagetab) {
		    $osimagetab=xCAT::Table->new('osimage', -create=>1);
		}
		(my $ref) = $osimagetab->getAttribs({imagename => $imagename}, 'osvers', 'osarch', 'profile', 'provmethod');
		if ($ref) {
		    $img_hash{$imagename}->{osver}=$ref->{'osvers'};
		    $img_hash{$imagename}->{osarch}=$ref->{'osarch'};
		    $img_hash{$imagename}->{profile}=$ref->{'profile'};
		    $img_hash{$imagename}->{provmethod}=$ref->{'provmethod'};
		    if (!$linuximagetab) {
			$linuximagetab=xCAT::Table->new('linuximage', -create=>1);
		    }
		    (my $ref1) = $linuximagetab->getAttribs({imagename => $imagename}, 'template', 'pkgdir', 'pkglist', 'partitionfile', 'driverupdatesrc', 'netdrivers');
		    if ($ref1) {
			if ($ref1->{'template'}) {
			    $img_hash{$imagename}->{template}=$ref1->{'template'};
			}
			if ($ref1->{'pkgdir'}) {
			    $img_hash{$imagename}->{pkgdir}=$ref1->{'pkgdir'};
			}
			if ($ref1->{'pkglist'}) {
			    $img_hash{$imagename}->{pkglist}=$ref1->{'pkglist'};
			}
            if ($ref1->{'partitionfile'}) {
                $img_hash{$imagename}->{partitionfile}=$ref1->{'partitionfile'};
            }
			if ($ref1->{'driverupdatesrc'}) {
			    $img_hash{$imagename}->{driverupdatesrc}=$ref1->{'driverupdatesrc'};
			}
			if ($ref1->{'netdrivers'}) {
			    $img_hash{$imagename}->{netdrivers}=$ref1->{'netdrivers'};
			}
		    }
		} else {
		    $callback->(
			{error     => ["The os image $imagename does not exists on the osimage table for $node"],
			 errorcode => [1]});
		    next;
		}
	    }
	    my $ph=$img_hash{$imagename};
	    $os = $ph->{osver};
	    $arch  = $ph->{osarch};
	    $profile = $ph->{profile};
	
	    $tmplfile=$ph->{template};
            $pkgdir=$ph->{pkgdir};
	    if (!$pkgdir) {
		$pkgdir="$installroot/$os/$arch";
	    }
	    $pkglistfile=$ph->{pkglist};
        $partfile=$ph->{partitionfile};
	    $netdrivers = $ph->{netdrivers};
	    $driverupdatesrc = $ph->{driverupdatesrc};
	}
	else {
	    $os = $ent->{os};
	    $arch    = $ent->{arch};
	    $profile = $ent->{profile};
	    if($os =~/sles.*/){
		$plat = "sles";
	    }elsif($os =~/suse.*/){
		$plat = "suse";
	    }else{
		$plat = "foobar";
		print "You should never get here!  Programmer error!";
		return;
	    }

		$tmplfile=xCAT::SvrUtils::get_tmpl_file_name("$installroot/custom/install/$plat", $profile, $os, $arch);
		if (! $tmplfile) { $tmplfile=xCAT::SvrUtils::get_tmpl_file_name("$::XCATROOT/share/xcat/install/$plat", $profile, $os, $arch); }

	    $pkglistfile=xCAT::SvrUtils::get_pkglist_file_name("$installroot/custom/install/$plat", $profile, $os, $arch);
	    if (! $pkglistfile) { $pkglistfile=xCAT::SvrUtils::get_pkglist_file_name("$::XCATROOT/share/xcat/install/$plat", $profile, $os, $arch); }

	    $pkgdir="$installroot/$os/$arch";

        #get the partition file from the linuximage table
        my $imgname = "$os-$arch-install-$profile";

        if (! $linuximagetab) {
            $linuximagetab = xCAT::Table->new('linuximage');
        }

        if ( $linuximagetab ) {
            (my $ref1) = $linuximagetab->getAttribs({imagename => $imgname}, 'partitionfile');
            if ( $ref1 and $ref1->{'partitionfile'}){
                $partfile = $ref1->{'partitionfile'};
            }
        }
        else {
            $callback->(
                { error => [qq{ Cannot find the linux image called "$imgname", maybe you need to use the "nodeset <nr> osimage=<your_image_name>" command to set the boot state}], errorcode => [1] }
            );
        }
	}
	

	unless ($os and $arch and $profile)
	{
	    $callback->(
		{
		    error     => ["No profile defined in nodetype or osimage table for $node"],
		    errorcode => [1]
		}
		);
	    next;
	}

        
	unless ( -r "$tmplfile")     
        {
            $callback->(
                      {
                       error =>
                         ["No AutoYaST template exists for " . $ent->{profile} . " in directory $installroot/custom/install/$plat or $::XCATROOT/share/xcat/install/$plat"],
                       errorcode => [1]
                      }
                      );
            next;
        }

        #Call the Template class to do substitution to produce a kickstart file in the autoinst dir
        my $tmperr;
        if (-r "$tmplfile")
        {
            $tmperr =
              xCAT::Template->subvars(
                         $tmplfile,
                         "$installroot/autoinst/$node",
                         $node,
		         $pkglistfile,
		         $pkgdir,
                 undef,
                 $partfile
                         );
        }

        if ($tmperr)
        {
            $callback->(
                        {
                         node => [
                                  {
                                   name      => [$node],
                                   error     => [$tmperr],
                                   errorcode => [1]
                                  }
                         ]
                        }
                        );
            next;
        }
	
		# create the node-specific post script DEPRECATED, don't do
		#mkpath "/install/postscripts/";
		#xCAT::Postage->writescript($node, "/install/postscripts/".$node, "install", $callback);

        if (
            (
             $arch =~ /x86_64/
             and -r "$pkgdir/1/boot/$arch/loader/linux"
             and -r "$pkgdir/1/boot/$arch/loader/initrd"
            )
            or
            (
             $arch =~ /x86$/
             and -r "$pkgdir/1/boot/i386/loader/linux"
             and -r "$pkgdir/1/boot/i386/loader/initrd"
            )
            or ($arch =~ /ppc/ and -r "$pkgdir/1/suseboot/inst64")
          )
        {


            #TODO: driver slipstream, targetted for network.
            unless ($doneimgs{"$os|$arch|$profile|$tftpdir"})
            {
                my $tftppath;
                if ($profile) {
                    $tftppath = "/$tftpdir/xcat/$os/$arch/$profile";
                } else {
                    $tftppath = "/$tftpdir/xcat/$os/$arch";
                }
                mkpath("$tftppath");
                if ($arch =~ /x86_64/)
                {
                    copy("$pkgdir/1/boot/$arch/loader/linux", "$tftppath");
                    copy("$pkgdir/1/boot/$arch/loader/initrd", "$tftppath");
                    @dd_drivers = &insert_dd($callback, $os, $arch, "$tftppath/initrd", $driverupdatesrc, $netdrivers);
                } elsif ($arch =~ /x86/) {
                    copy("$pkgdir/1/boot/i386/loader/linux", "$tftppath");
                    copy("$pkgdir/1/boot/i386/loader/initrd", "$tftppath");
                    @dd_drivers = &insert_dd($callback, $os, $arch, "$tftppath/initrd", $driverupdatesrc, $netdrivers);
                }
                elsif ($arch =~ /ppc/)
                {
                    copy("$pkgdir/1/suseboot/inst64", "$tftppath");
                    @dd_drivers = &insert_dd($callback, $os, $arch, "$tftppath/inst64", $driverupdatesrc, $netdrivers);
                }
                $doneimgs{"$os|$arch|$profile|$tftpdir"} = 1;
            }

            #We have a shot...
            my $ent    = $resents->{$node}->[0]; 
            my $sent = $hments->{$node}->[0]; #hmtab->getNodeAttribs($node, ['serialport', 'serialspeed', 'serialflow']);

            my $netserver;
            if ($ent and $ent->{xcatmaster}) {
                $netserver = $ent->{xcatmaster};
            } else {
                $netserver = '!myipfn!';
            }
            if ($ent and $ent->{nfsserver})
            {
		$netserver = $ent->{nfsserver};
            }
            my $kcmdline =
                "quiet autoyast=$httpmethod://"
              . $netserver . ":" . $httpport
              . "/install/autoinst/"
              . $node
              . " install=$httpmethod://"
              . $netserver . ":" . $httpport
              . "/install/$os/$arch/1";

            my $netdev = "";
            if ($ent->{installnic})
            {
                if ($ent->{installnic} eq "mac")
                {
                    my $mactab = xCAT::Table->new("mac");
                    my $macref = $mactab->getNodeAttribs($node, ['mac']);
                    $netdev = $macref->{mac};
                 }
                else
                {
                    $netdev = $ent->{installnic};
                }
            }
            elsif ($ent->{primarynic})
            {
                if ($ent->{primarynic} eq "mac")
                {
                    my $mactab = xCAT::Table->new("mac");
                    my $macref = $mactab->getNodeAttribs($node, ['mac']);
                    $netdev = $macref->{mac};
                }
                else
                {
                    $netdev = $ent->{primarynic};
                }
            }
            else
            {
                $netdev = "bootif";
            }
            if ($netdev eq "") #why it is blank, no mac defined?
            {
                $callback->(
                    {
                        error => ["No mac.mac for $node defined"],
                        errorcode => [1]
                    }
                );
            }
            unless ($netdev eq "bootif") { #if going by bootif, BOOTIF will suffice
                $kcmdline .= " netdevice=" . $netdev;
            }

            # Add the kernel paramets for driver update disk loading
            foreach (@dd_drivers) {
                $kcmdline .= " dud=file:/cus_driverdisk/$_";
            }

            if (defined $sent->{serialport})
            {
                unless ($sent->{serialspeed})
                {
                    $callback->(
                        {
                         error => [
                             "serialport defined, but no serialspeed for $node in nodehm table"
                         ],
                         errorcode => [1]
                        }
                        );
                    next;
                }
                $kcmdline .=
                    " console=tty0 console=ttyS"
                  . $sent->{serialport} . ","
                  . $sent->{serialspeed};
                if ($sent and ($sent->{serialflow} =~ /(ctsrts|cts|hard)/))
                {
                    $kcmdline .= "n8r";
                }
            }
            # for pSLES installation, the dhcp request may timeout
            # due to spanning tree settings or multiple network adapters.
            # use dhcptimeout=150 to avoid dhcp timeout
            if ($arch =~ /ppc/)
            {
                $kcmdline .= " dhcptimeout=150";
            }

            my $kernelpath;
            my $initrdpath;
            
            if ($arch =~ /x86/)
            {
                if ($profile) {
                    $kernelpath = "xcat/$os/$arch/$profile/linux";
                    $initrdpath = "xcat/$os/$arch/$profile/initrd";
                } else {
                    $kernelpath = "xcat/$os/$arch/linux";
                    $initrdpath = "xcat/$os/$arch/initrd";
                }
                $bptab->setNodeAttribs(
                                        $node,
                                        {
                                         kernel   => $kernelpath,
                                         initrd   => $initrdpath,
                                         kcmdline => $kcmdline
                                        }
                                        );
            }
            elsif ($arch =~ /ppc/)
            {
                if ($profile) {
                    $kernelpath = "xcat/$os/$arch/$profile/inst64";
                } else {
                    $kernelpath = "xcat/$os/$arch/inst64";
                }
                $bptab->setNodeAttribs(
                                        $node,
                                        {
                                         kernel   => $kernelpath,
                                         initrd   => "",
                                         kcmdline => $kcmdline
                                        }
                                        );
            }

        }
        else
        {
            $callback->(
                {
                 error => [
                     "Failed to detect copycd configured install source at /install/$os/$arch"
                 ],
                 errorcode => [1]
                }
                );
        }
    }
    #my $rc = xCAT::TableUtils->create_postscripts_tar();
    #if ($rc != 0)
    #{
    #    xCAT::MsgUtils->message("S", "Error creating postscripts tar file.");
    #}
}

sub copycd
{
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $distname = "";
    my $detdistname = "";
    my $installroot;
    my $arch;
    my $path;
    my $mntpath=undef;
    my $inspection=undef;
    my $noosimage=undef;


    $installroot = "/install";
    #my $sitetab = xCAT::Table->new('site');
    #if ($sitetab)
    #{
        #(my $ref) = $sitetab->getAttribs({key => 'installdir'}, 'value');
        #print Dumper($ref);
        my @entries =  xCAT::TableUtils->get_site_attribute("installdir");
        my $t_entry = $entries[0];
        if ( defined($t_entry) ) {
            $installroot = $t_entry;
        }
    #}

    @ARGV = @{$request->{arg}};
    GetOptions(
               'n=s' => \$distname,
               'a=s' => \$arch,
               'm=s' => \$mntpath,
	       'i'   => \$inspection,
               'p=s' => \$path,
	       'o'   => \$noosimage,
               );
    unless ($mntpath)
    {

        #this plugin needs $mntpath...
        return;
    }
    if ($distname and $distname !~ /^sles|^suse/)
    {

        #If they say to call it something other than SLES or SUSE, give up?
        return;
    }
    unless (-r $mntpath . "/content")
    {
        return;
    }
    my $dinfo;
    open($dinfo, $mntpath . "/content");
    my $darch;
    while (<$dinfo>)
    {
        if (m/^DEFAULTBASE\s+(\S+)/)
        {
            $darch = $1;
            chomp($darch);
            last;
        }
        if (not $darch and m/^BASEARCHS\s+(\S+)/) {
            $darch = $1;
        }
    }
    close($dinfo);
    unless ($darch)
    {
        return;
    }
    my $dirh;
    opendir($dirh, $mntpath);
    my $discnumber;
    my $totaldiscnumber;
    while (my $pname = readdir($dirh))
    {
        if ($pname =~ /media.(\d+)/)
        {
            $discnumber = $1;
            chomp($discnumber);
            my $mfile;
            open($mfile, $mntpath . "/" . $pname . "/media");
            <$mfile>;
            <$mfile>;
            $totaldiscnumber = <$mfile>;
            chomp($totaldiscnumber);
            close($mfile);
            open($mfile, $mntpath . "/" . $pname . "/products");
            my $prod = <$mfile>;
            close($mfile);

            if ($prod =~ m/SUSE-Linux-Enterprise-Server/ || $prod =~ m/SUSE-Linux-Enterprise-Software-Development-Kit/)
            {
                if (-f "$mntpath/content") {
                    my $content;
                    open($content,"<","$mntpath/content");
                    my @contents = <$content>;
                    close($content);
                    foreach (@contents) {
                        if (/^VERSION/) {
                            my @verpair = split;
                            $detdistname = "sles".$verpair[1];
                            unless ($distname) { $distname = $detdistname; }
                        }
                    }
                } else {
                    my @parts    = split /\s+/, $prod;
                    my @subparts = split /-/,   $parts[2];
                    $detdistname = "sles" . $subparts[0];
                    unless ($distname) { $distname = "sles" . $subparts[0] };
                }
                if($prod =~ m/Software-Development-Kit/) {
                    $discnumber = 'sdk' . $discnumber;
                }
		# check media.1/products for text.  
		# the cselx is a special GE built version.
		# openSUSE is the normal one.
            }elsif($prod =~ m/cselx 1.0-0|openSUSE 11.1-0/){
			$distname = "suse11";
                	$detdistname = "suse11";
		}
	    
        }
    }

    unless ($distname and $discnumber)
    {
        return;
    }




    if ($darch and $darch =~ /i.86/)
    {
        $darch = "x86";
    }
    elsif ($darch and $darch =~ /ppc/)
    {
        $darch = "ppc64";
    }
    if ($darch)
    {
        unless ($arch)
        {
            $arch = $darch;
        }
        if ($arch and $arch ne $darch)
        {
            $callback->(
                     {
                      error =>
                        ["Requested SLES architecture $arch, but media is $darch"],
                        errorcode => [1]
                     }
                     );
            return;
        }
    }

    if($inspection)
    {
            $callback->(
                {
                 info =>
                   "DISTNAME:$distname\n"."ARCH:$arch\n"."DISCNO:$discnumber\n"
                }
                );
            return;
    }

    %{$request} = ();    #clear request we've got it.



    my $defaultpath="$installroot/$distname/$arch";
    unless($path)
    {
        $path=$defaultpath;
    }

    my $ospkgpath= "$path/$discnumber";

    if(-l $ospkgpath)
    {
        unlink($ospkgpath);
    }elsif(-d $ospkgpath)
    {
	rmtree($ospkgpath);	
    }
    mkpath("$ospkgpath");

    my $omask = umask 0022;
    umask $omask;

    $callback->(
         {data => "Copying media to $ospkgpath"});

    my $rc;
    $SIG{INT} =  $SIG{TERM} = sub { 
       foreach(@cpiopid){
          kill 2, $_; 
       }
       if ($mntpath) {
            chdir("/");
            system("umount $mntpath");
       }
    };
    my $kid;
    chdir $mntpath;
    my $numFiles = `find . -print | wc -l`;
    my $child = open($kid,"|-");
    unless (defined $child) {
      $callback->({error=>"Media copy operation fork failure"});
      return;
    }
    if ($child) {
       push @cpiopid,$child;
       my @finddata = `find .`;
       for (@finddata) {
          print $kid $_;
       }
       close($kid);
       $rc = $?;
    } else {
        my $c = "nice -n 20 cpio -vdump $ospkgpath";
        my $k2 = open(PIPE, "$c 2>&1 |") ||
           $callback->({error => "Media copy operation fork failure"});
	push @cpiopid, $k2;
        my $copied = 0;
        my ($percent, $fout);
        while(<PIPE>){
          next if /^cpio:/;
          $percent = $copied / $numFiles;
          $fout = sprintf "%0.2f%%", $percent * 100;
          $callback->({sinfo => "$fout"});
          ++$copied;
        }
        exit;
    }
    #  system(
    #    "cd $path; find . | nice -n 20 cpio -dump $installroot/$distname/$arch/$discnumber/"
    #    );
    chmod 0755, "$path";
    chmod 0755, "$ospkgpath"; 


    unless($path =~ /^($defaultpath)/)
    {
	mkpath("$defaultpath/$discnumber");
        if(-d "$defaultpath/$discnumber")
        {
                rmtree("$defaultpath/$discnumber");
        }
        else
        {
                unlink("$defaultpath/$discnumber");
        }

        my $hassymlink = eval { symlink("",""); 1 };
        if ($hassymlink) {
                symlink($ospkgpath,"$defaultpath/$discnumber");
        }else
        {
                link($ospkgpath,"$defaultpath/$discnumber");
        }

    }

    if ($detdistname eq "sles10.2" and $discnumber eq "1") { #Go and correct inst_startup.ycp in the install root
        my $tmnt = tempdir("xcat-sles.$$.XXXXXX",TMPDIR=>1);
        my $tdir = tempdir("xcat-slesd.$$.XXXXXX",TMPDIR=>1);
        my $startupfile;
        my $ycparch = $arch;
        if ($arch eq "x86") { 
            $ycparch = "i386";
        }
        system("mount -o loop $installroot/$distname/$arch/$discnumber/boot/$ycparch/root $tmnt");
        system("cd $tmnt;find . |cpio -dump $tdir");
        system("umount $tmnt;rm $installroot/$distname/$arch/$discnumber/boot/$ycparch/root");
        open($startupfile,"<","$tdir/usr/share/YaST2/clients/inst_startup.ycp");
        my @ycpcontents = <$startupfile>;
        my @newcontents;
        my $writecont=1;
        close($startupfile);
        foreach (@ycpcontents) {
            if (/No hard disks/) {
                $writecont=0;
            } elsif (/\}/) {
                $writecont=1;
            }
            s/cancel/next/;
            if ($writecont) {
                push @newcontents, $_;
            } 
        }
        open($startupfile,">","$tdir/usr/share/YaST2/clients/inst_startup.ycp");
        foreach (@newcontents) {
            print $startupfile $_;
        }
        close($startupfile);
        system("cd $tdir;mkfs.cramfs . $installroot/$distname/$arch/$discnumber/boot/$ycparch/root");
        system("rm -rf $tmnt $tdir");
    }

    if ($rc != 0)
    {
        $callback->({error => "Media copy operation failed, status $rc"});
    }
    else
    {
        $callback->({data => "Media copy operation successful"});
	my $osdistroname=$distname."-".$arch;
	my @ret=xCAT::SvrUtils->update_osdistro_table($distname,$arch,$path,$osdistroname);
        if ($ret[0] != 0) {
            $callback->({data => "Error when updating the osdistro tables: " . $ret[1]});
        }
	
	unless($noosimage){
   	   my @ret=xCAT::SvrUtils->update_tables_with_templates($distname, $arch,$path,$osdistroname);
	   if ($ret[0] != 0) {
	       $callback->({data => "Error when updating the osimage tables: " . $ret[1]});
	   }
           
	   my @ret=xCAT::SvrUtils->update_tables_with_diskless_image($distname, $arch, undef, "netboot",$path,$osdistroname);
	   if ($ret[0] != 0) {
	       $callback->({data => "Error when updating the osimage tables for stateless: " . $ret[1]});
	   }

           my @ret=xCAT::SvrUtils->update_tables_with_diskless_image($distname, $arch, undef, "statelite",$path,$osdistroname);
	   if ($ret[0] != 0) {
	       $callback->({data => "Error when updating the osimage tables for statelite: " . $ret[1]});
	   }
	}
    }
}

# callback subroutine for 'find' command to return the path
my $driver_name;
my $real_path;
sub get_path ()
{
    if ($File::Find::name =~ /\/$driver_name/) {
        $real_path = $File::Find::name;
    }
}

# Get the driver disk or driver rpm from the osimage.driverupdatesrc
# The valid value: dud:/install/dud/dd.img,rpm:/install/rpm/d.rpm, if missing the tag: 'dud'/'rpm'
# the 'rpm' is default.
#
# If cannot find the driver disk from osimage.driverupdatesrc, will try to search driver disk 
# from /install/driverdisk/<os>/<arch>
#
# For driver rpm, the driver list will be gotten from osimage.netdrivers. If not set, copy all the drivers from driver 
# rpm to the initrd.
#

sub insert_dd () {
    my $callback = shift;
    my $os = shift;
    my $arch = shift;
    my $img = shift;
    my $driverupdatesrc = shift;
    my $drivers = shift;

    my $install_dir = xCAT::TableUtils->getInstallDir();

    my $cmd;
    
    my @dd_list;
    my @rpm_list;
    my @driver_list;
    my $Injectalldriver;

    my @rpm_drivers;

    # Parse the parameters to the the source of Driver update disk and Driver rpm, and driver list as well
    if ($driverupdatesrc) {
        my @srcs = split(',', $driverupdatesrc);
        foreach my $src (@srcs) {
            if ($src =~ /dud:(.*)/i) {
                push @dd_list, $1;
            } elsif ($src =~ /rpm:(.*)/i) {
                push @rpm_list, $1;
            } else {
                push @rpm_list, $src;
            }
        }
    }
    if (! @dd_list) {
        # get Driver update disk from the default path if not specified in osimage
        # check the Driver Update Disk images, it can be .img or .iso
        if (-d "$install_dir/driverdisk/$os/$arch") {
            $cmd = "find $install_dir/driverdisk/$os/$arch -type f";
            @dd_list = xCAT::Utils->runcmd($cmd, -1);
        }
    }

    foreach (split /,/,$drivers) {
        if (/^allupdate$/) {
            $Injectalldriver = 1;
            next;
        }
        unless (/\.ko$/) {
            s/$/.ko/;
        }
        push @driver_list, $_;
    }

    chomp(@dd_list);
    chomp(@rpm_list);
    
    unless (@dd_list || (@rpm_list && ($Injectalldriver || @driver_list))) {
        return ();
    }

    # Create the tmp dir for dd hack
    my $dd_dir = mkdtemp("/tmp/ddtmpXXXXXXX");
    mkpath "$dd_dir/initrd_img";

    
    my $pkgdir="$install_dir/$os/$arch";
    # Unzip the original initrd
    # This only needs to be done for ppc or handling the driver rpm
    # For the driver disk against x86, append the driver disk to initrd directly
    if ($arch =~/ppc/ || (@rpm_list && ($Injectalldriver || @driver_list))) {
        if ($arch =~ /ppc/) {
            $cmd = "gunzip --quiet -c $pkgdir/1/suseboot/initrd64 > $dd_dir/initrd";
        } elsif ($arch =~ /x86/) {
            $cmd = "gunzip --quiet -c $img > $dd_dir/initrd";
        }
        xCAT::Utils->runcmd($cmd, -1);
        if ($::RUNCMD_RC != 0) {
            my $rsp;
            push @{$rsp->{data}}, "Handle the driver update failed. Could not gunzip the initial initrd.";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return ();
        }
        
        # Unpack the initrd
        $cmd = "cd $dd_dir/initrd_img; cpio -id --quiet < $dd_dir/initrd";
        xCAT::Utils->runcmd($cmd, -1);
        if ($::RUNCMD_RC != 0) {
            my $rsp;
            push @{$rsp->{data}}, "Handle the driver update disk failed. Could not extract files from the initial initrd.";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return ();
        }

        # Start to load the drivers from rpm packages
        if (@rpm_list && ($Injectalldriver || @driver_list)) {
            # Extract the files from rpm to the tmp dir
            mkpath "$dd_dir/rpm";
            foreach my $rpm (@rpm_list) {
                if (-r $rpm) {
                    $cmd = "cd $dd_dir/rpm; rpm2cpio $rpm | cpio -idum";
                    xCAT::Utils->runcmd($cmd, -1);
                    if ($::RUNCMD_RC != 0) {
                        my $rsp;
                        push @{$rsp->{data}}, "Handle the driver update failed. Could not extract files from the rpm $rpm.";
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }
                } else {
                    my $rsp;
                    push @{$rsp->{data}}, "Handle the driver update failed. Could not read the rpm $rpm.";
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }
            }
            
            # Copy the firmware to the rootimage
            if (-d "$dd_dir/rpm/lib/firmware") {
                if (! -d "$dd_dir/initrd_img/lib") {
                    mkpath "$dd_dir/initrd_img/lib";
                }
                $cmd = "cp -rf $dd_dir/rpm/lib/firmware $dd_dir/initrd_img/lib";
                xCAT::Utils->runcmd($cmd, -1);
                if ($::RUNCMD_RC != 0) {
                    my $rsp;
                    push @{$rsp->{data}}, "Handle the driver update failed. Could not copy firmware to the initrd.";
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }
            }
            
            # Copy the drivers to the rootimage
            # Figure out the kernel version
            my @kernelpaths = <$dd_dir/initrd_img/lib/modules/*>;
            my @kernelvers;
            foreach (@kernelpaths) {
                push @kernelvers, basename($_);
            }
                    
            foreach my $kernelver (@kernelvers) {
              if (@driver_list) {
                # copy the specific drivers to initrd
                foreach my $driver (@driver_list) {
                  $driver_name = $driver;
                  $real_path = "";
                  find(\&get_path, <$dd_dir/rpm/lib/modules/$kernelver/*>);
                  if ($real_path && $real_path =~ m!$dd_dir/rpm(/lib/modules/$kernelver/.*?)[^\/]*$!) {
                      if (! -d "$dd_dir/initrd_img$1") {
                          mkpath "$dd_dir/initrd_img$1";
                      }
                      $cmd = "cp -rf $real_path $dd_dir/initrd_img$1";
                      xCAT::Utils->runcmd($cmd, -1);
                      if ($::RUNCMD_RC != 0) {
                          my $rsp;
                          push @{$rsp->{data}}, "Handle the driver update failed. Could not copy driver $driver to the initrd.";
                          xCAT::MsgUtils->message("I", $rsp, $callback);
                      } else {
                          push @rpm_drivers, $driver;
                      }
                  }
                }
              } elsif ($Injectalldriver) {
                # copy all the drviers to the initrd
                if (-d "$dd_dir/rpm/lib/modules/$kernelver") {
                    $cmd = "cp -rf $dd_dir/rpm/lib/modules/$kernelver $dd_dir/initrd_img/lib/modules/";
                    xCAT::Utils->runcmd($cmd, -1);
                    if ($::RUNCMD_RC != 0) {
                        my $rsp;
                        push @{$rsp->{data}}, "Handle the driver update failed. Could not copy /lib/modules/$kernelver to the initrd.";
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }
                } else {
                    my $rsp;
                    push @{$rsp->{data}}, "Handle the driver update failed. Could not find /lib/modules/$kernelver from the driver rpms.";
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }
            }
    
            # regenerate the modules dependency
            foreach my $kernelver (@kernelvers) {
                $cmd = "cd $dd_dir/initrd_img; depmod -b . $kernelver";
                xCAT::Utils->runcmd($cmd, -1);
                if ($::RUNCMD_RC != 0) {
                    my $rsp;
                    push @{$rsp->{data}}, "Handle the driver update failed. Could not generate the depdency for the drivers in the initrd.";
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }
            }
          }
        } # end of loading drivers from rpm packages 
    }
    
    # Create the dir for driver update disk
    mkpath("$dd_dir/initrd_img/cus_driverdisk");

    # insert the driver update disk into the cus_driverdisk dir
    foreach my $dd (@dd_list) {
        copy($dd, "$dd_dir/initrd_img/cus_driverdisk");
    }
    
    # Repack the initrd
    # In order to avoid the runcmd add the '2>&1' at end of the cpio
    # cmd, the echo cmd is added at the end
    $cmd = "cd $dd_dir/initrd_img; find . -print | cpio -H newc -o > $dd_dir/initrd | echo";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC != 0) {
        my $rsp;
        push @{$rsp->{data}}, "Handle the driver update disk failed. Could not pack the hacked initrd.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return ();
    }

    # zip the initrd
    #move ("$dd_dir/initrd.new", "$dd_dir/initrd");
    $cmd = "gzip -f $dd_dir/initrd";
    xCAT::Utils->runcmd($cmd, -1);

    if ($arch =~/ppc/ || (@rpm_list && ($Injectalldriver || @driver_list))) {
        if ($arch =~/ppc/) {
            # make sure the src kernel existed
            $cmd = "gunzip -c $pkgdir/1/suseboot/linux64.gz > $dd_dir/kernel";
            xCAT::Utils->runcmd($cmd, -1);
            
            # create the zimage
            $cmd = "env -u POSIXLY_CORRECT /lib/lilo/scripts/make_zimage_chrp.sh --vmlinux $dd_dir/kernel --initrd $dd_dir/initrd.gz --output $img";
            xCAT::Utils->runcmd($cmd, -1);
            if ($::RUNCMD_RC != 0) {
                my $rsp;
                push @{$rsp->{data}}, "Handle the driver update disk failed. Could not pack the hacked initrd.";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return ();
            }
        } elsif ($arch =~/x86/) {
            copy ("$dd_dir/initrd.gz", "$img");
        }
    } elsif ($arch =~ /x86/) {
        my $rdhandle;
        my $ddhandle;
        open($rdhandle,">>",$img);
        open ($ddhandle,"<","$dd_dir/initrd.gz");
        binmode($rdhandle);
        binmode($ddhandle);
        { local $/ = 32768; my $block; while ($block = <$ddhandle>) { print $rdhandle $block; } }
        close($rdhandle);
        close($ddhandle);
    }
    
    # clean the env
    system("rm -rf $dd_dir");

    my $rsp;
    if (@dd_list) {
        push @{$rsp->{data}}, "Inserted the driver update disk:".join(',', sort(@dd_list)).".";
    }
    if (@driver_list) {
        push @{$rsp->{data}}, "Inserted the drivers:".join(',', sort(@rpm_drivers))." from driver packages.";
    } elsif (@rpm_list && ($Injectalldriver || @driver_list)) {
         push @{$rsp->{data}}, "Inserted the drivers from driver packages:".join(',', sort(@rpm_list)).".";
    }
    xCAT::MsgUtils->message("I", $rsp, $callback);

    my @dd_files = ();
    foreach my $dd (sort(@dd_list)) {
        chomp($dd);
	$dd =~ s/^.*\///;
	push @dd_files, $dd;
    }

    return sort(@dd_files);    
}

#sub get_tmpl_file_name {
#  my $base=shift;
#  my $profile=shift;
#  my $os=shift;
#  my $arch=shift;
#  if (-r   "$base/$profile.$os.$arch.tmpl") {
#    return "$base/$profile.$os.$arch.tmpl";
#  }
#  elsif (-r "$base/$profile.$os.tmpl") {
#    return  "$base/$profile.$os.tmpl";
#  }
#  elsif (-r "$base/$profile.$arch.tmpl") {
#    return  "$base/$profile.$arch.tmpl";
#  }
#  elsif (-r "$base/$profile.tmpl") {
#    return  "$base/$profile.tmpl";
#  }
#
#  return "";
#}

1;
