package YEP::Mirror::RpmMd;
use strict;

use LWP::UserAgent;
use URI;
use XML::Parser;
use File::Path;
use File::Find;
use Crypt::SSLeay;
use IO::Zlib;
use Time::HiRes qw(gettimeofday tv_interval);
use Digest::SHA1  qw(sha1 sha1_hex);

use YEP::Mirror::Job;

BEGIN 
{
    if(exists $ENV{https_proxy})
    {
        # required for Crypt::SSLeay HTTPS Proxy support
        $ENV{HTTPS_PROXY} = $ENV{https_proxy};
    }
}

# constructor
sub new
{
    my $pkgname = shift;
    my %opt   = @_;
    
    my $self  = {};
    $self->{URI}   = undef;
    # local destination ie: /var/repo/download.suse.org/foo/10.3
    $self->{LOCALPATH}   = undef;
    $self->{JOBS}   = [];
    $self->{VERIFYJOBS}   = [];
    $self->{STATISTIC}->{DOWNLOAD} = 0;
    $self->{STATISTIC}->{UPTODATE} = 0;
    $self->{STATISTIC}->{ERROR}    = 0;
    $self->{CLEANLIST} = {};
    $self->{DEBUG} = 0;
    $self->{LASTUPTODATE} = 0;
    $self->{REMOVEINVALID} = 0;

    # stores the verifiy state
    # when verify task is running

    # current job
    $self->{VERIFY}->{CURRENT}  = undef;
    # State of the resource
    # 0 out the tag
    # 1 inside the resource
    # 2 inside checksum
    # 3 inside open-checksum
    # 4 inside timestamp
    # 5 inside location
    # -1 other
    #
    # as only checksums have text data, the others
    # will not probably be used.
    $self->{VERIFY}->{STATE} = 0;

    # state of the type of resource we are in
    # 0 repomd.xml data
    # 1 patches list patch
    # 2 pattern list pattern
    # 3 a patch definition
    # -1 other
    $self->{VERIFY}->{CURRENTFILE} = undef;

    # Do _NOT_ set env_proxy for LWP::UserAgent, this would break https proxy support
    $self->{USERAGENT}  = LWP::UserAgent->new(keep_alive => 1);
    if(exists $ENV{http_proxy})
    {
        $self->{USERAGENT}->proxy("http",  $ENV{http_proxy});
    }

    if(exists $opt{debug} && defined $opt{debug} && $opt{debug})
    {
        $self->{DEBUG} = 1;
    }
    
    bless($self);
    return $self;
}

# URI property
sub uri
{
    my $self = shift;
    if (@_) { $self->{URI} = shift }
    return $self->{URI};
}

# creates a path from a url
sub localUrlPath()
{
  my $self = shift;
  my $uri;
  my $repodest;

  $uri = URI->new($self->{URI});
  $repodest = join( "/", ( $uri->host, $uri->path ) );
  return $repodest;
}

sub lastUpToDate()
{
    my $self = shift;
    return $self->{LASTUPTODATE};
}

# mirrors the repository to destination
sub mirrorTo()
{
    my $self = shift;
    my $dest = shift;
    my $options = shift;
  
    if ( not -e $dest )
    { die $dest . " does not exist"; }
    my $t0 = [gettimeofday] ;
    
    # reset the counter
    $self->{STATISTIC}->{ERROR}    = 0;
    $self->{STATISTIC}->{UPTODATE} = 0;
    $self->{STATISTIC}->{DOWNLOAD} = 0;

    # extract the url components to create
    # the destination directory
    # so we save the repo to:
    # $destdir/hostname.com/path
    my $uri = URI->new($self->{URI});

    if ( defined $options && exists $options->{ urltree } && $options->{ urltree } == 1 )
    {
      $self->{LOCALPATH} = join( "/", ( $dest, $self->localUrlPath() ) );
    }
    else
    {
      $self->{LOCALPATH} = $dest;
    }
    print "Mirroring: ", $self->{URI}, "\n";
    print "Target:    ", $self->{LOCALPATH}, "\n";

    my $destfile = join( "/", ( $self->{LOCALPATH}, "repodata/repomd.xml" ) );

    # get the repository index
    my $job = YEP::Mirror::Job->new(debug => $self->{DEBUG}, UserAgent => $self->{USERAGENT});
    $job->uri( $self->{URI} );
    $job->localdir( $self->{LOCALPATH} );

    # get the file
    $job->resource( "/repodata/repomd.xml" );

    # check if we need to mirror first
    if ( not $job->outdated() )
    {
      # repomd is the same
      # check if the local repository is valid
      if ( $self->verify($self->{LOCALPATH}, {removeinvalid => 1}) )
      {
          print "=> Finished mirroring ".$self->{URI}." All files are up-to-date.\n\n";
          $self->{LASTUPTODATE} = 1;
          return 0;
      }
      else
      {
          # we should continue here
          print "repomd.xml is the same, but repo is not valid. Start mirroring.\n";

          # just in case
          $self->{LASTUPTODATE} = 0;
          # reset the counter
          $self->{STATISTIC}->{ERROR}    = 0;
          $self->{STATISTIC}->{UPTODATE} = 0;
          $self->{STATISTIC}->{DOWNLOAD} = 0;
      }
    }

    my $result = $job->mirror();
    if( $result == 1 )
    {
        $self->{STATISTIC}->{ERROR} += 1;
    }
    elsif( $result == 2 )
    {
        $self->{STATISTIC}->{UPTODATE} += 1;
    }
    else
    {
        $self->{STATISTIC}->{DOWNLOAD} += 1;
    }
    
    $job->resource( "/repodata/repomd.xml.asc" );
    $result = $job->mirror();
    if( $result == 1 )
    {
        $self->{STATISTIC}->{ERROR} += 1;
    }
    elsif( $result == 2 )
    {
        $self->{STATISTIC}->{UPTODATE} += 1;
    }
    else
    {
        $self->{STATISTIC}->{DOWNLOAD} += 1;
    }

    $job->resource( "/repodata/repomd.xml.key" );
    $result = $job->mirror();
    if( $result == 1 )
    {
        $self->{STATISTIC}->{ERROR} += 1;
    }
    elsif( $result == 2 )
    {
        $self->{STATISTIC}->{UPTODATE} += 1;
    }
    else
    {
        $self->{STATISTIC}->{DOWNLOAD} += 1;
    }

    # parse it and find more resources
    $self->_parseXmlResource( $destfile );

    my $lastresource = "";
    foreach ( sort {$a->resource cmp $b->resource} @{$self->{JOBS}} )
    {
        # skip duplicates
        next if( $lastresource eq $_->resource() );
        $lastresource = $_->resource();
        
        my $mres = $_->mirror();
        if( $mres == 1 )
        {
            $self->{STATISTIC}->{ERROR} += 1;
        }
        elsif( $mres == 2 )
        {
            $self->{STATISTIC}->{UPTODATE} += 1;
        }
        else
        {
            $self->{STATISTIC}->{DOWNLOAD} += 1;
        }
    }

    print "=> Finished mirroring ".$self->{URI}."\n";
    print "=> Downloaded Files: ".$self->{STATISTIC}->{DOWNLOAD}."\n";
    print "=> Up to date Files: ".$self->{STATISTIC}->{UPTODATE}."\n";
    print "=> Download Errors : ".$self->{STATISTIC}->{ERROR}."\n";
    print "=> Mirror Time:      ".(tv_interval($t0))." seconds\n";
    print "\n";

    return $self->{STATISTIC}->{ERROR};
}

# deletes all files not referenced in
# the rpmmd resource chain
sub clean()
{
    my $self = shift;
    my $dest = shift;
    
    if ( not -e $dest )
    { die "Destination '$dest' does not exist"; }

    $self->{LOCALPATH} = $dest;

    print "Cleaning:         ", $self->{LOCALPATH}, "\n";

    # algorithm
    
    find ( { wanted =>
             sub
             {
                 if ( -f $File::Find::name )
                 { $self->{CLEANLIST}->{$File::Find::name} = 1; }
             }
             , no_chdir => 1 }, $self->{LOCALPATH} );

    
    my $path = $self->{LOCALPATH}."/repodata/repomd.xml";
    $self->_parseXmlResource( $path, 1);
    # strip out /./ and //
    $path =~ s/\/\.?\//\//g;

    delete $self->{CLEANLIST}->{$path} if (exists $self->{CLEANLIST}->{$path});
    delete $self->{CLEANLIST}->{$path.".asc"} if (exists $self->{CLEANLIST}->{$path.".asc"});;
    delete $self->{CLEANLIST}->{$path.".key"} if (exists $self->{CLEANLIST}->{$path.".key"});;

    my $cnt = 0;
    foreach my $file ( keys %{$self->{CLEANLIST}} )
    {
        print "Delete: $file\n" if ($self->{DEBUG});
        $cnt += unlink $file;
    }

    print "Finished cleaning ", $self->{LOCALPATH}, "\n";
    print "Removed files:    $cnt\n";
    print "\n";
}

# parses a xml resource
sub _parseXmlResource()
{
    my $self     = shift;
    my $path     = shift;
    my $forClean = shift || 0;
    my $parser   = undef;    
    
    if(!$forClean)
    {
        $parser = XML::Parser->new( Handlers =>
                                    { Start=> sub { mirror_handle_start_tag($self, @_) },
                                      End=>\&mirror_handle_end_tag,
                                    });
    }
    else
    {
        $parser = XML::Parser->new( Handlers =>
                                    { Start=> sub { handle_start_tag_clean($self, @_) },
                                      End=>\& mirror_handle_end_tag,
                                    });
    }

    if ( $path =~ /(.+)\.gz/ )
    {
      my $fh = IO::Zlib->new($path, "rb");
      eval {
          # using ->parse( $fh ) result in errors
          #my @cont = $fh->getlines();
          #$parser->parse( join("", @cont ));
          $parser->parse( $fh );
      };
      if($@) {
          # ignore the errors, but print them
          chomp($@);
          print STDERR "Error: $@\n";
      }
    }
    else
    {
      eval {
          $parser->parsefile( $path );
      };
      if($@) {
          # ignore the errors, but print them
          chomp($@);
          print STDERR "Error: $@\n";
      }
    }
}

# verifies the repository on path
sub verify()
{
    my $self = shift;
    my $path = shift;
    my $options = shift;

    # if path was not defined, we can use last
    # mirror destination dir
    if ( $path )
    {
        $self->{LOCALPATH} = $path;
    }

    # remove invalid packages?
    if ( defined $options && exists $options->{removeinvalid} && $options->{removeinvalid} == 1 )
    {
        $self->{REMOVEINVALID}  = 1;
    }

    if ( not -e $self->{LOCALPATH} )
    { die $self->{LOCALPATH} . " does not exist"; }

    my $t0 = [gettimeofday] ;

    print "Verifying:    ", $self->{LOCALPATH}, "\n";

    my $destfile = join( "/", ( $self->{LOCALPATH}, "repodata/repomd.xml" ) );

    $self->{STATISTIC}->{ERROR} = 0;
    
    # parse it and find more resources
    $self->_verifyXmlResource( $destfile );

    my $job;
    foreach ( sort {$a->resource cmp $b->resource} @{$self->{VERIFYJOBS}} )
    {
        # skip duplicates
        $job = $_ if ! $job;
        next if( $job->resource eq $_->resource );
        $job = $_;

        #print STDERR "Verify: " . $job->resource . " : ";
        print "Verify: ". $job->resource . ": " if ($self->{DEBUG});
        my $ok = $job->verify();
        if ($ok || ($job->resource eq "/repodata/repomd.xml") )
        {
            print "OK\n" if ($self->{DEBUG});
            #print STDERR "OK\n";
        }
        else
        {
          #print STDERR "FAILED: " . $job->resource . ": \n";
          print "FAILED ( ".$job->checksum." vs ".$job->realchecksum ." )\n";
          #print STDERR "FAILED ( " .$job->checksum. " vs " . $job->realchecksum . ")\n";
          $self->{STATISTIC}->{ERROR} += 1;
          if ($self->{REMOVEINVALID} == 1)
          {
            print "Deleting ".$job->resource."\n";
            unlink($job->local) ;
          }
        }
    }

    print "=> Finished verifying: ".$self->{LOCALPATH}."\n";
    print "=> Errors            : ".$self->{STATISTIC}->{ERROR}."\n";
    print "=> Verify Time       : ".(tv_interval($t0))." seconds\n";
    print "\n";

    $self->{REMOVEINVALID}  = 0;
    return ($self->{STATISTIC}->{ERROR} == 0);
}


# parses a xml resource
sub _verifyXmlResource()
{
    my $self = shift;
    my $path = shift;

    my $oldfile = $self->{VERIFY}->{CURRENTFILE};
    $self->{VERIFY}->{CURRENTFILE} = $path;

    my $parser = XML::Parser->new( Handlers =>
                                   { Start=> sub { verify_handle_start_tag($self, @_) },
                                     End=>=> sub { verify_handle_end_tag($self, @_) },
                                     Char => sub { verify_handle_char($self, @_) }
                                   });
    if ( $path =~ /(.+)\.gz/ )
    {
      my $fh = IO::Zlib->new($path, "rb");
      eval {
          # using ->parse( $fh ) result in errors
          #my @cont = $fh->getlines();
          #$parser->parse( join("", @cont ));
          $parser->parse( $fh );
      };
      if($@) {
          # ignore the errors, but print them
          chomp($@);
          print STDERR "Error: $@\n";
      }
    }
    else
    {
        eval {
            $parser->parsefile( $path );
        };
        if($@) {
            # ignore the errors, but print them
            chomp($@);
            print STDERR "Error: $@\n";
        }
    }
    $self->{VERIFY}->{CURRENTFILE} = $oldfile;
}


# handles XML reader start tag events
sub mirror_handle_start_tag()
{
    my $self = shift;
    my( $expat, $element, %attrs ) = @_;
    # ask the expat object about our position
    my $line = $expat->current_line;

    # we are looking for <location href="foo"/>
    if ( $element eq "location" )
    {
        # get the repository index
        my $job = YEP::Mirror::Job->new(debug => $self->{DEBUG}, UserAgent => $self->{USERAGENT});
        $job->resource( $attrs{"href"} );
        $job->localdir( $self->{LOCALPATH} );
        $job->uri( $self->{URI} );

        # if it is an xml file we have to download it now and
        # process it
        if (  $job->resource =~ /(.+)\.xml(.*)/ )
        {
          # mirror it first, so we can parse it
            my $mres = $job->mirror();
            if( $mres == 1 )
            {
                $self->{STATISTIC}->{ERROR} += 1;
            }
            elsif( $mres == 2 )
            {
                $self->{STATISTIC}->{UPTODATE} += 1;
            }
            else
            {
                $self->{STATISTIC}->{DOWNLOAD} += 1;
            }
            
            $self->_parseXmlResource( $job->local() );
        }
        else
        {
            # download it later
            if ( $job->resource )
            {
              push @{$self->{JOBS}}, $job;
            }
            else
            {
              print STDERR "no resource on $job->local";
            }
        }
    }
}

# handles XML reader start tag events for clean
sub handle_start_tag_clean()
{
    my $self = shift;
    my( $expat, $element, %attrs ) = @_;
    # ask the expat object about our position
    my $line = $expat->current_line;

    # we are looking for <location href="foo"/>
    if ( $element eq "location" )
    {
        # get the repository index
        my $resource = $self->{LOCALPATH}."/".$attrs{"href"};
        # strip out /./ and //
        $resource =~ s/\/\.?\//\//g;

        # if this path is in the CLEANLIST, delete it
        delete $self->{CLEANLIST}->{$resource} if (exists $self->{CLEANLIST}->{$resource});

        # if it is an xml file we have to download it now and
        # process it
        if (  $resource =~ /(.+)\.xml(.*)/ )
        {
            $self->_parseXmlResource( $resource, 1);
        }
    }
}

sub mirror_handle_end_tag()
{
  my( $expat, $element, %attrs ) = @_;
}

# handles XML reader start tag events
# for verification
sub verify_handle_start_tag()
{
    my $self = shift;
    my( $expat, $element, %attrs ) = @_;
    # ask the expat object about our position
    my $line = $expat->current_line;

    if ( ( ( $element eq "data" ) || ( $element eq "patch" ) || ( $element eq "package" ) ) &&
         ( $self->{VERIFY}->{STATE} eq 0 ) )
    {
        $self->{VERIFY}->{STATE} = 1;

        # at the start of a new resource, the current job
        # should be null
        if ( ( not exists $self->{VERIFY}->{CURRENT}) && ( not defined $self->{VERIFY}->{CURRENT}) )
        {
          print STDERR "Unexpected tag '$element' at line $line\n";
          $self->{STATISTIC}->{ERROR} += 1;
          return 0;
        }

        $self->{VERIFY}->{CURRENT} = YEP::Mirror::Job->new();
        $self->{VERIFY}->{CURRENT}->localdir( $self->{LOCALPATH} );
        return 1;
    }

    # we are looking for <location href="foo"/>
    if ( ( $element eq "location" ) && ( $self->{VERIFY}->{STATE} eq 1 ) )
    {
        # should had been defined at beginin of the
        # resource start tag
        if ( ( not exists $self->{VERIFY}->{CURRENT}) && ( not defined $self->{VERIFY}->{CURRENT}) )
        {
            print STDERR "Unexpected tag '$element' at line $line\n";
            $self->{STATISTIC}->{ERROR} += 1;
            return 0;
        }
 
        $self->{VERIFY}->{CURRENT}->resource( $attrs{"href"} );
        return 1;
    }

    if ( ( $element eq "checksum") && ( $self->{VERIFY}->{STATE} eq 1 ) )
    {
        $self->{VERIFY}->{STATE} = 2;
        # should had been defined at beginin of the
        # resource start tag
        if ( ( not exists $self->{VERIFY}->{CURRENT}) && ( not defined $self->{VERIFY}->{CURRENT}) )
        {
          print STDERR "Unexpected tag 'checksum' at line: " . $line . "\n";
          $self->{STATISTIC}->{ERROR} += 1;
          return 0;
        }

        $self->{VERIFY}->{CURRENT}->checksum( $attrs{"href"} );
        return 1;
    }

    if ( ( $element eq "open-checksum") && ( $self->{VERIFY}->{STATE} eq 1 ) )
    {
      $self->{VERIFY}->{STATE} = 3;
    }

    if ( ( $element eq "timestamp") && ( $self->{VERIFY}->{STATE} eq 1 ) )
    {
      $self->{VERIFY}->{STATE} = 4;
    }
}

sub verify_handle_char()
{
    my $self = shift;
    my( $expat, $text ) = @_;

    # checksum state
    # capture the checksum itself
    if ( $self->{VERIFY}->{STATE} eq 2 )
    {
        my $checksum = $self->{VERIFY}->{CURRENT}->checksum;
        
        if(defined $checksum && $checksum ne "")
        {
            # sometimes we got not the complete checksum in once
            $checksum .= $text;
        }
        else
        {
            $checksum = $text;
        }
        
        $self->{VERIFY}->{CURRENT}->checksum( $checksum );
    }
}

sub verify_handle_end_tag()
{
    my $self = shift;
    my( $expat, $element, %attrs ) = @_;

    if ( ( ( $element eq "checksum"      ) ||
           ( $element eq "location"      ) ||
           ( $element eq "timestamp"     ) ||
           ( $element eq "open-checksum" ) ) &&
         ( $self->{VERIFY}->{STATE} > 1 ) )
    {
        # back to state 1
        $self->{VERIFY}->{STATE} = 1;
    }
    elsif ( ( ( $element eq "data"    ) ||
              ( $element eq "patch"   ) ||
              ( $element eq "package" ) ||
              ( $element eq "pattern" )    ) &&
            ( $self->{VERIFY}->{STATE} eq 1 ) )
    {
      $self->{VERIFY}->{STATE} = 0;

      # verify it later
      my $job = $self->{VERIFY}->{CURRENT};
      
      if ( not ( $self->{VERIFY}->{CURRENTFILE} =~ /^(.+)patch-(.+)\.xml(.*)/ && $element eq "patch" ) )
      {
        push @{$self->{VERIFYJOBS}}, $job;
      }

      #print STDERR $self->{VERIFY}->{CURRENTFILE} . "\n";

      if ($self->{VERIFY}->{CURRENT}->resource =~ /(.+)\.xml(.*)/)
      {
        if ( (not $self->{VERIFY}->{CURRENT}->resource =~ /(.*)\/filelists\.xml(.*)/ ) &&
             (not $self->{VERIFY}->{CURRENT}->resource =~ /(.*)\/other\.xml(.*)/ ) )
        {
          $self->{VERIFY}->{CURRENT} = undef;
          #print STDERR " Ver " . $self->{VERIFY}->{CURRENT}->resource . "\n" ;
          $self->_verifyXmlResource( $job->local );
        }
      }
      
      $self->{VERIFY}->{CURRENT} = undef;
    }
}


=head1 NAME

YEP::Mirror::RpmMd - mirroring of a rpm metadata repository

=head1 SYNOPSIS

  use YEP::Mirror::RpmMd;

  $mirror = YEP::Mirror::RpmMd->new();
  $mirror->uri( "http://repo.com/10.3" );

  $mirror->mirrorTo( "/somedir", { urltree => 1 });
  $mirror->verify("/somedir/www.foo.com/repo");

  $mirror->mirrorTo( "/somedir", { urltree => 0 });
  $mirror->verify("/somedir");

  # this is true if the last mirror call determined
  # the reposiotory was up to date.
  # if no mirror was run, then it is false
  $mirror->lastUpToDate()


=head1 DESCRIPTION

Mirroring of a rpm metadata repository.

The mirror function will not download the same files twice.

In order to clean the repository, that is removing all files
which are not mentioned in the metadata, you can use the clean method:

 $mirror->clean();

=head1 METHODS

=over 4

=item new([$params])

Create a new YEP::Mirror::RpmMd object:

  my $mirror = YEP::Mirror::RpmMd->new(debug => 1);

Arguments are an anonymous hash array of parameters:

=over 4

=item debug

Set to 1 to enable debug. 

=back

=item uri()

 $mirror->uri( "http://repo.com/10.3" );

 Specify the YUM source where to mirror from.

=item mirrorTo()

 $mirror->mirrorTo( "/somedir", { urltree => 1 });

 Sepecify the target directory where to place the mirrored files.
 Returns the count of errors.

=over 4

=item urltree

The option urltree of the mirror method controls 
how the repo is mirrored. If urltree is true, then subdirectories
with the hostname and path of the repo url are created inside the
target directory.
If urltree is false, then the repo is mirrored right below the target
directory.

=back

=item verify()

 $mirror->verify();

 Returns true, if the repo is valid, otherwise false

=back

=head1 AUTHOR

dmacvicar@suse.de

=head1 COPYRIGHT

Copyright 2007, 2008 SUSE LINUX Products GmbH, Nuernberg, Germany.


=cut


1;  # so the require or use succeeds
