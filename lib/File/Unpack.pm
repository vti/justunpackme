#
# (C) 2010-2011, jnw@cpan.org, all rights reserved.
# Distribute under the same license as Perl itself.
#
#
# sudo zypper -v in perl-Compress-Raw-Zlib
#  -> 'nothing to do'
# sudo zypper -v in 'perl-Compress-Raw-Zlib >= 2.027'
#  -> 'perl' providing 'perl-Compress-Raw-Zlib >= 2.027' is already installed.
# sudo zypper -v in --force perl-Compress-Raw-Zlib
#  -> works, 
# sudo zypper -v in --from 12 perl-Compress-Raw-Zlib
#  -> works, if d.l.p is repo #12.
# 
# TODO: 
# * evaluate File::Extract - Extract Text From Arbitrary File Types 
#       (HTML, PDF, Plain, RTF, Excel)
#
# * make taint checks really check things, instead of $1 if m{^(.*)$};
#
# * Implement disk space monitoring.
#
# * formats:
#   - use lzmadec/xzdec as fallback to lzcat.
#   - glest has bzipped tar files named glest-1.0.10-data.tar.bz2.tar;
#   - Not all suffixes are appended by . e.g. openh323-v1_15_2-src-tar.bz2 is different.
#   - gzip -dc can unpack old compress .Z, add its mime-type
#   - java-1_5_0-sun hides zip-files in shell scripts with suffix .bin
#   - cpio fails on \.delta\.rpm
#   - rpm files should extract all header info in readable format.
#   - do we rely on rpm2cpio to handle them all: 
#      rpm -qp --nodigest --nosignature --qf "%{PAYLOADCOMPRESSOR}" $f 
#   - m{\.(otf|ttf|ps|eps)$}i)
#   - application/x-frame		# xorg-modular/doc/xorg-docs/specs/XPRINT/xp_libraryTOC.doc
#
# * blacklisting?
#      # th_en_US.dat is an 11MB thesaurus in OOo
#      skip if $from =~ m{(/(ustar|pax)\-big\-\d+g\.tar\.bz2|/th_en_US\.dat|/testtar\.tar|\.html\.(ru|ja|ko\.euc-kr|fr|es|cz))$}
#
# * use LWP::Simple::getstore() if $archive =~ m{^\w+://}
# * application/x-debian-package is a 'application/x-archive' -> (ar xv /dev/stdin) < $qufrom";
# * application/x-iso9660	-> "isoinfo -d -i %(src)s"
# * PDF improvement: okular says: 'this document contains embedded files.' How can we grab those?

use warnings;
use strict;

package File::Unpack;

BEGIN
{
 # Requires: shared-mime-info
 eval 'use File::LibMagic;';		# only needed in mime(); mime() dies, if missing
 eval 'use File::MimeInfo::Magic;';	# only needed in mime(); okay, if missing.
 eval 'use Compress::Raw::Lzma;';	# only needed in mime(); for finding lzma.
 eval 'use Compress::Raw::Bzip2;';	# only needed in mime(); for finding second level types
 eval 'use Compress::Raw::Zlib;';	# only needed in mime(); for finding second level types
 eval 'use BSD::Resource;';		# setrlimit
 eval 'use Filesys::Statvfs;';		# statvfs();
}

use Carp;
use File::Path;
use File::Temp ();		# tempdir() in _run_mime_handler.
use File::Copy ();
use File::Compare ();
use JSON;
use String::ShellQuote;		# used in _prep_configdir 
use IPC::Run;			# implements File::Unpack::run()
use Text::Sprintf::Named;	# used to parse @builtin_mime_handlers
use Cwd 'getcwd';		# run(), moves us there and back. 
use Data::Dumper;
use POSIX ();

=head1 NAME

File::Unpack - An aggressive bz2/gz/zip/tar/cpio/rpm/deb/cab/lzma/7z/rar/... archive unpacker, based on mime-types

=head1 VERSION

Version 0.39

=cut

our $VERSION = '0.39';

POSIX::setlocale(&POSIX::LC_ALL, 'C');
$ENV{PATH} = '/usr/bin:/bin';
$ENV{SHELL} = '/bin/sh';
delete $ENV{ENV};

# what we name the temporary directories, while helpers are working.
my $TMPDIR_TEMPL = '_fu_XXXXX';

# no longer used by the tick-tick ticker to show where we are.
# my $lsof = '/usr/bin/lsof';

# Compress::Raw::Bunzip2 needs several 100k of input data, we special case this.
# File::LibMagic wants to read ca. 70k of input data, before it says application/vnd.ms-excel
# Anything else works with 1024.
my $UNCOMP_BUFSZ = 1024;

# unpack will give up, after unpacking that many levels. It is more likely we
# got into a loop by then, than really have that many levels.
my $RECURSION_LIMIT = 200;

# Suggested place, where admins should install the helpers bundled with this module.
sub _default_helper_dir { $ENV{FILE_UNPACK_HELPER_DIR}||'/usr/share/File-Unpack/helper' }

# we use '=' in the mime_name, this expands to '/(x\-|ANY\+)?'

my @builtin_mime_handlers = (
  # mimetype pattern          # suffix_re           # command with redirects, as defined with IPC::Run::run

  # Requires: xz bzip2 gzip unzip
  [ 'application=xz',        qr{(?:xz|lz(ma)?)},   [qw(/usr/bin/lzcat)],  qw(< %(src)s       > %(destfile)s) ],
  [ 'application=xz',        qr{(?:xz|lz(ma)?)},   [qw(/usr/bin/xz      -dc    %(src)s)], qw(> %(destfile)s) ],
  [ 'application=lzma',      qr{(?:xz|lz(ma)?)},   [qw(/usr/bin/lzcat)],  qw(< %(src)s       > %(destfile)s) ],
  [ 'application=lzma',      qr{(?:xz|lz(ma)?)},   [qw(/usr/bin/xz      -dc    %(src)s)], qw(> %(destfile)s) ],
  [ 'application=bzip2',     qr{bz2},           [qw(/usr/bin/bunzip2 -dc -f %(src)s)], qw(> %(destfile)s) ],
  [ 'application=gzip',      qr{(?:gz|Z)},         [qw(/usr/bin/gzip -dc -f %(src)s)], qw(> %(destfile)s) ],
  [ 'application=compress',  qr{(?:gz|Z)},         [qw(/usr/bin/gzip -dc -f %(src)s)], qw(> %(destfile)s) ],

  # Requires: sharutils
  [ 'text=uuencode',        qr{uu},                [qw(/usr/bin/uudecode -o %(destfile)s %(src)s)] ],

  # Requires: upx
  [ 'application=upx',	   qr{(?:upx\.exe|upx)},   [qw(/usr/bin/upx -q -q -q -d -o%(destfile)s %(src)s) ] ],

  # xml.summary.Mono.Security.Authenticode is twice inside of monodoc-1.0.4.tar.gz/Mono.zip/ -> use -o
  [ 'application=zip',        qr{(?:zip|jar|sar)}, [qw(/usr/bin/unzip -P no_pw -q -o %(src)s)] ],

  # Requires: unrar
  [ 'application=rar',	      qr{rar},             [qw(/usr/bin/unrar x -o- -p- -inul -kb -y %(src)s)] ],
  # Requires: lha
  [ 'application=x-lha',      qr{lha},             [qw(/usr/bin/lha x -q %(src)s)] ],

  # Requires: binutils
  [ 'application=archive',    qr{(?:a|ar|deb)},    [qw(/usr/bin/ar x %(src)s)] ],
  [ 'application=x-deb',      qr{(?:a|ar|deb)},    [qw(/usr/bin/ar x %(src)s)] ],

  # Requires: cabextract
  [ 'application/vnd.ms-cab-compressed', qr{cab},  [qw(/usr/bin/cabextract -q %(src)s)] ],

  # Requires: p7zip
  [ 'application/x-7z-compressed', qr{7z},	   [qw(/usr/bin/p7zip -d %(src)s)] ],
  #[ 'application/x-7z-compressed', qr{7z},	   [qw(/usr/bin/7z x -pPass -y  %(src)s)] ],

  # Requires: tar rpm cpio
  [ 'application=tar',       qr{(?:tar|gem)},      [\&_locate_tar,  qw(-xf %(src)s)] ],
  [ 'application=tar+bzip2', qr{tar\.bz2},         [\&_locate_tar, qw(-jxf %(src)s)] ],
  [ 'application=tar+gzip',  qr{t(?:ar\.gz|gz)},   [\&_locate_tar, qw(-zxf %(src)s)] ],
#  [ 'application=tar+gzip',  qr{t(?:ar\.gz|gz)},      [qw(/home/testy/src/C/slowcat)], qw(< %(src)s |), [\&_locate_tar, qw(-zxf -)] ],
  [ 'application=tar+lzma',  qr{tar\.(?:xz|lzma|lz)}, [qw(/usr/bin/lzcat)], qw(< %(src)s |), [\&_locate_tar, qw(-xf -)] ],
  [ 'application=tar+lzma',  qr{tar\.(?:xz|lzma|lz)}, [qw(/usr/bin/xz -dc -f %(src)s)], '|', [\&_locate_tar, qw(-xf -)] ],
  [ 'application=rpm',       qr{(?:src\.r|s|r)pm}, [qw(/usr/bin/rpm2cpio %(src)s)], '|', [\&_locate_cpio_i] ],
  [ 'application=cpio',      qr{cpio},             [\&_locate_cpio_i], qw(< %(src)s) ],

  # Requires: poppler-tools
  [ 'application=pdf',	      qr{pdf}, [qw(/usr/bin/pdftotext %(src)s %(destfile)s.txt)], '&', [qw(/usr/bin/pdfimages -j %(src)s pdfimages)] ],
);

## CAUTION keep _my_shell_quote in sync with all _locate_* functions.
sub _locate_tar
{
  my $self = shift;
  return @{$self->{_locate_tar}} if defined $self->{_locate_tar};

  # cannot use tar -C %(destdir)s,  we rely on being chdir'ed inside already :-)
  # E: /bin/tar: /tmp/xxx/_VASn/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_: Cannot chdir: Permission denied

  my @tar = (-f '/bin/tar' ? '/bin/tar' : '/usr/bin/tar' );
  ## osc co loves to create directories with : in them. 
  ## Tell tar to accept such directories as directores.
  push @tar, "--force-local" 
    unless $self->run([@tar, "--force-local", "--help"], { out_err => '/dev/null' });
  push @tar, "--no-unquote"  
    unless $self->run([@tar, "--no-unquote", "--help"],  { out_err => '/dev/null'});

  $self->{_locate_tar} = \@tar;
  return @tar;
}

sub _locate_cpio_i
{
  my $self = shift;
  return @{$self->{_locate_cpio_i}} if defined $self->{_locate_cpio_i};

  my @cpio_i = ('/usr/bin/cpio', '-idm');
  $cpio_i[1] .= 'u' 
    unless run(['/usr/bin/cpio', '-idmu', '--usage'], {out_err => '/dev/null'});
  push @cpio_i, '--sparse'
    unless run([@cpio_i, '--sparse', '--usage'], {out_err => '/dev/null'});
  push @cpio_i, '--no-absolute-filenames'
    unless run([@cpio_i, '--no-absolute-filenames', '--usage'], {out_err => '/dev/null'});
  push @cpio_i, '--force-local'
    unless run([@cpio_i, '--force-local', '--usage'], {out_err => '/dev/null'});

  @{$self->{_locate_cpio_i}} = \@cpio_i;
  return @cpio_i;
}

=head1 SYNOPSIS

This perl module comes with an executable script:

/usr/bin/file_unpack -h

/usr/bin/file_unpack [-1] [-m] ARCHIVE...


File::Unpack is an aggressive unpacker for archive files. Aggressive means, it can 
recursivly descend into freshly unpacked files, if they are archives themselves.
It also uncompresses files where needed. File::Unpack will extract
as much readable text (ascii or any other encoding) as possible.
Most of the currently known archive file formats are supported.

    use File::Unpack;

    my $log;
    my $u = File::Unpack->new(logfile => \$log);

    my $m = $u->mime('/etc/init.d/rc');
    print "$m->[0]; charset=$m->[1]\n";
    # text/x-shellscript; charset=us-ascii

    map { print "$_->{name}\n" } @{$u->mime_handler()};
    # application/%rpm
    # application/%tar+gzip
    # application/%tar+bzip2
    # ...

    $u->unpack("inputfile.tar.bz2");
    while ($log =~ m{^\s*"(.*?)":}g) # it's JSON.
      {
        print "$1\n"; 	# report all files unpacked
      }

    ...

C<unpack()> examines the contents of an archive file or directory using an extensive 
mime-type analysis. The contents is unpacked recursively to the given destination
directory; a listing of the unpacked files is reported through the built in
logging facility during unpacking. Most common archive file formats are handled 
directly; more can easily be added as mime-type helper plugins.

=head1 SUBROUTINES/METHODS

=head2 new

my $u = new(destdir => '.', logfile => \*STDOUT, maxfilesize => '2G', verbose => 1);

Creates an unpacker instance. The parameter C<destdir> must be a writable location; all output 
files and directories are placed inside this destdir. Subdirectories will be
created in an attempt to reflect the structure of the input. Destdir defaults
to the current directory; relative paths are resolved immediatly, so that
chdir() after calling new is harmless.

The parameter C<logfile> can be a reference to a scalar, a filename, or a filedescriptor.
The logfile starts with a JSON formatted prolog, where all lines start 
with printable characters.
For each file unpacked, a one line record is appended, starting with a single 
whitespace ' ', and terminated by "\n". The format is a JSON-encoded C<< "key":
{value},\n >> pair, where key is the filename, and value is a hash including 'mime',
'size', and other information.
The logfile is terminated by an epilog, where each line starts with a printable character.
As part of the epilog, a dummy file named "\" with an empty hash is added to the list. 
It should be ignored while parsing.
Per default, the logfile is sent to STDOUT. 

The parameter C<maxfilesize> is a safeguard against compressed sparse files and test-files for archivers. 
Such files could easily fill up any available disk space when unpacked. Files hitting this limit will 
be silently truncated.  Check the logfile records or epilog to see if this has happened.
BSD::Resource is used manipulate RLIMIT_FSIZE.

The parameter C<one_shot> can optionally be set to non-zero, to limit unpacking to one step of unpacking.
Unpacking of well known compressed archives like e.g. '.tar.bz2' is considered one step only. If uncompressing 
is considered an extra step depends on the configured mime helpers.

=head2 exclude

exclude(add => ['.svn', '*.orig' ], del => '.svn', force => 1)

Defines the exclude-list for unpacking. This list is advisory for the mime-handlers. 
The exclude-list items are shell glob patterns, where '*' or '?' never match '/'.

You can use force to have any of these removed after unpacking.
Use (vcs => 1) to exclude a long list of known version control system directories, use (vcs => 0) to remove them.
The default is C<< exclude(empty => 1) >>, which is the same as C<< exclude(empty_file => 1, empty_dir => 1) >> -- 
having the obvious meaning.

(re => 1) returns the active exclude-list as a regexp pattern. 
Otherwise C<exclude> always returns the list as an array ref.

Symbolic links are always excluded.

=cut

sub _glob_list_re
{
  my @re;
  return unless @_;
  for my $text (@_)
    {
      # Taken from pdb2perl:glob2re() and adapted, to not match slashes in wildcards.
      # This should be kept compatible with tar --exclude .

      $text =~ s{([\.\(\)\[\]\{\}])}{\\$1}g; ## protect magic re characters.
      $text =~ s{\*}{[^/]*}g;                  ## * -> [^/]*
      $text =~ s{\?}{[^/]}g;                   ## ? -> [^/]
      push @re, $text;
    }
  return '(/|^)(' . join('|', @re) . ')(/|$)';
}

sub _not_excluded
{
  my $self = shift;
  my ($dir, $file) = @_;

  return 1 unless my $re = $self->{exclude}{re};

  $dir ||= '';
  $dir .= '/' unless $dir =~ m{/$};
  $file = $dir . $file;

  return 0 if $file =~ m{$re};
  return 1; 
}

sub exclude 
{
  my $self = shift;
  my %opt = $#_ ? @_ : (add => $_[0]);
  
  # ADD to this list from: https://build.opensuse.org/project/show?project=devel%3Atools%3Ascm
  my @vcs = qw(SCCS RCS CVS .svn .git .hg .osc);

  $opt{add} = [ $opt{add} ] unless ref $opt{add};
  $opt{del} = [ $opt{del} ] unless ref $opt{del};

  push @{$opt{add}}, @vcs if defined $opt{vcs} and $opt{vcs};
  push @{$opt{del}}, @vcs if defined $opt{vcs} and !$opt{vcs};

  for my $a (@{$opt{add}})
    {
      $self->{exclude}{list}{$a}++ if defined $a;
    }
  
  for my $a (@{$opt{del}})
    {
      delete $self->{exclude}{list}{$a} if defined $a;
    }

  my @list = sort keys %{$self->{exclude}{list}};
  $self->{exclude}{re} = _glob_list_re(@list);

  $opt{empty_dir} = $opt{empty_file} = $opt{empty} if defined $opt{empty};

  for my $o qw(empty_file empty_dir force)
    {
      $self->{exclude}{$o} = $opt{$o} if defined $opt{$o};
    }

  return $opt{re} ? $self->{exclude}{re} : \@list;
}

=begin private 

=item log, logf

The C<log> method is used by C<unpack> to send text to the logfile.
The C<logf> method takes a filename and a hash, and logs a JSON formatted line.

=end private

=cut
sub log
{
  my $self = shift;
  if (my $fp = $self->{lfp})
    {
      print $fp @_;
      $self->{lfp_printed}++;
    }
}

sub logf
{
  my ($self,$file,$hash,$suff) = @_;
  $suff = ",\n" unless defined $suff;
  my $json = $self->{json} ||= JSON->new()->ascii(1);
  if (my $fp = $self->{lfp})
    {
      $self->log(qq[{ "oops": "logf used before prolog??",\n"unpacked_files":{\n])
        unless tell $fp; # }}
      my $str = $json->encode({$file => $hash});
      $str =~ s{^\{}{}s;
      $str =~ s{\}$}{}s;
      die "logf failed to encode newline char: $str\n" if $str =~ m{(?:\n|\r)};
      $self->log(" $str$suff");
    }
}

$SIG{'XFSZ'} = sub
{
  print STDERR "soft RLIMIT_FSIZE exceeded. SIGXFSZ recieved. Exiting\n";
  exit;
};

# if this returns 0, we test again and call it again, possibly.
# if this returns nonzero, we just continue.
sub _default_fs_warn
{
  carp "Filesystem (@_) is almost full.\n $0 paused for 30 sec.\n";
  sleep(30);
  return 0;	
}

## returns 1, if enough space free.
## returns 0, if warn-method was called, and returned nonzero
## returns -1, if no warn method
## or does not return at all, and rechecks the status
##  with at least on second delay, if warn-method returns 0.
sub _fs_check
{
  my ($self, $needed_b, $needed_i, $needed_p) = @_;
  $needed_b = '1M' unless defined $needed_b;	# bytes
  $needed_i = 100  unless defined $needed_i;	# inodes
  $needed_p = 1.0  unless defined $needed_p;	# percent
  $needed_b = _bytes_unit($needed_b);

  my $DIR;
  open $DIR, "<", $self->{destdir} or 
  opendir $DIR, $self->{destdir} or return;
  ## fileno() does not work with opendir() handles.
  my $fd = fileno($DIR); return unless defined $fd;

  for (;;)
    {
      my $st = eval { [ fstatvfs($fd) ] };
      my $total_b = $st->[1] * $st->[2];	# f_frsize * f_blocks
      my $free_b  = $st->[0] * $st->[4];	# f_bsize * f_bavail
      my $free_i  = $st->[7];			# f_favail
      my $perc = 100.0 * ($total_b - $free_b) / ($total_b||1);

      return 1 if $free_b >= $needed_b && 
                  $free_i >= $needed_i && 
		  (100-$perc > $needed_p);
	
      return -1 unless $self->{fs_warn};
      my $w = $self->{fs_warn}->($self->{destdir}, $perc, $free_b, $free_i);
      return 0 if $w;
      sleep 1;
    }
}

sub new
{
  my $self = shift;
  my $class = ref($self) || $self;
  my %obj = (ref $_[0] eq 'HASH') ? %{$_[0]} : @_;

  $obj{verbose} = 1 unless defined $obj{verbose};
  $obj{destdir} ||= '.';
  $obj{logfile} ||= \*STDOUT;
  $obj{maxfilesize} = $ENV{'FILE_UNPACK_MAXFILESIZE'}||'2.5G' unless defined $obj{maxfilesize};
  $obj{maxfilesize} = _bytes_unit($obj{maxfilesize});
  $ENV{'FILE_UNPACK_MAXFILESIZE'} = $obj{maxfilesize};	# so that children see the same.

  mkpath($obj{destdir}); # abs_path is unreliable if destdir does not exist
  $obj{destdir} = Cwd::fast_abs_path($obj{destdir});
  $obj{destdir} =~ s{(.)/+$}{$1}; #  assert no trailing '/'.

  # used in unpack() to jail mime_handlers deep inside destdir:
  $obj{dot_dot_safeguard} = 20 unless defined $obj{dot_dot_safeguard};
  $obj{jail_chmod0} ||= 0;
  # used in unpack, blocks recursion after archive unpacking
  $obj{one_shot} ||= 0;

  carp "We are running as root: Malicious archives may clobber your filesystem.\n" unless $>;

  if (ref $obj{logfile} eq 'SCALAR' or !(ref $obj{logfile}))
    {
      open $obj{lfp}, ">", $obj{logfile} or croak "open logfile $obj{logfile} failed: $!\n";
    }
  else
    {
      $obj{lfp} = $obj{logfile};
    }
  $obj{lfp_printed} = 0;

  if ($obj{maxfilesize})
    {
      eval 
        { 
	  no strict; 
	  # helper/application=x-shellscript calls File::Unpack->new(), with defaults...
	  my @have = BSD::Resource::getrlimit(RLIMIT_FSIZE);
	  if ($have[0] == RLIM_INFINITY or $have[0] > $obj{maxfilesize})
	    {
	      # if RLIM_INFINITY is seen as an attempt to increase limits, we would fail. Ignore this.
	      BSD::Resource::setrlimit(RLIMIT_FSIZE, $obj{maxfilesize}, RLIM_INFINITY) or
	      BSD::Resource::setrlimit(RLIMIT_FSIZE, $obj{maxfilesize}, $obj{maxfilesize}) or
	      warn "RLIMIT_FSIZE($obj{maxfilesize}), limit=$have failed\n";
	    }
	};
      if ($@)
        {
          carp "WARNING maxfilesize=$obj{maxfilesize} ignored:\n $@ $!\n Maybe package perl-BSD-Resource is not installed??\n\n";
        }
    }

  $obj{minfree}{factor} = 10    unless defined $obj{minfree}{factor};
  $obj{minfree}{bytes}  = '1M'  unless defined $obj{minfree}{bytes};
  $obj{minfree}{percent} = '1%' unless defined $obj{minfree}{percent};
  minfree(\%obj, warning => $obj{fs_warn}||\&_default_fs_warn);

  $obj{exclude}{empty_dir} = 1  unless defined $obj{exclude}{empty_dir};
  $obj{exclude}{empty_file} = 1 unless defined $obj{exclude}{empty_file};

  $self = bless \%obj, $class;

  for my $h (@builtin_mime_handlers)
    {
      $self->mime_handler(@$h);
    }
  $obj{helper_dir} = _default_helper_dir unless exists $obj{helper_dir};
  $self->mime_handler_dir($obj{helper_dir}) if defined $obj{helper_dir} and -d $obj{helper_dir};

  unless ($ENV{PERL5LIB})
    {
      # in case we are using non-standard perl lib dirs, put them into the environment, 
      # so that any helper scripts see them too. They might need them, if written in perl.

      use Config;
      my $pat = qr{^(?:\Q$Config{vendorlib}\E|\Q$Config{sitelib}\E|\Q$Config{privlib}\E)\b};
      my @add;	# all dirs, that come before the standard dirs.
      for my $i (@INC)
        {
	  last if $i =~ m{$pat};
	  push @add, $i;
	}
      $ENV{PERL5LIB} = join ':', @add if @add;
    }

  return $self;
}

sub DESTROY
{
  my $self = shift;
  if ($self->{lfp} and $self->{lfp_printed})
    {
      # this should never happen. 
      # always delete $self->{lfp} manually, when done.
      ## {{
      $self->log(qq[\n}, "error":"unexpected destructor seen; lfp_printed=$self->{lfp_printed}; recursion_level=$self->{recursion_level}"};\n]);
      close $self->{lfp} if $self->{lfp} ne $self->{logfile};
      delete $self->{lfp};
      delete $self->{lfp_printed};
    }
  if ($self->{configdir})
    {
      rmtree($self->{configdir});
      delete $self->{configdir};
    }
}

=head2 unpack

$u->unpack($archive, [$destdir])

Determines the contents of an archive and recursivly extracts its files.  
An archive may be the pathname of a file or directory. The extracted contents will be 
stored in "destdir/$subdir/$dest_name", where dest_name is the filename
component of archive without any leading pathname components, and possibly
stripped or added suffix. (Subdir defaults to ''.) If archive is a directory,
then dest_name will also be a directory. If archive is a file, the type of
dest_name depends on the type of packing: If the archive expands to multiple
files, dest_name will be a directory, otherwise it will be a file. If a file of
the same name already exists in the destination subdir, an additional subdir
component is created to avoid any conflicts.
For each extracted file, a record is written to the logfile.
When unpacking is finished, the logfile contains one valid JSON structure.
Unpack achieves this by writing suitable prolog and epilog lines to the logfile.
The logfile can also be parsed line by line. All file records is one line and start 
with a ' ' whitespace, and end in a ',' comma. Everything else is prolog or epilog.

The actual unpacking is dispatched to mime-type specfic handlers,
selected using C<mime>. A mime-handler can either be built-in code, or an
external program (or shell-script) found in a directory registered with
C<mime_handler_dir>. The standard place for external handlers is
F</usr/share/File-Unpack/helper>; it can be changed by the environment variable
F<FILE_UNPACK_HELPER_DIR> or the C<new> parameter C<helper_dir>.

A mime-handler is called with 6 parameters:
source_path, destfile, destination_path, mimetype, description, and config_dir. 
Note, that destination_path is a freshly created empty working directory, even
if the unpacker is expected to unpack only a single file. The unpacker is
called after chdir into destination_path, so you usually do not need to
evaluate the third parameter.

The directory C<config_dir> contains unpack configuration in .sh, .js and possibly 
other formats. A mime-handler may use this information, but need not.  
All data passed into C<new> is reflected there, as well as the active exclude-list.
Using the config information can help a mime-handler to skip unwanted
work or otherwise optimize unpacking.

C<unpack> monitors the available filesystem space in destdir. If there is less space
than configured with C<minfree>, a warning can be printed and unpacking is
optionally paused. It also monitors the mime-handlers progress reading the archive 
at source_path and reports percentages to STDERR (if verbose is 1 or more).

After the mime-handler is finished, C<unpack> examines the files it created.
If it created no files in F<destdir>, an error is reported, and the
F<source_path> may be passed to other unpackers, or finally be added to the log as is.

If the mime-handler wants to express that F<source_path> is already unpacked as far as possible
and should be added to the log without any error messages, it creates a symbolic link 
F<destdir> pointing to F<source_path>.


The system considers replacing the
directory with a file, if all of the following conditions are met:

=over

=item *

There is exactly one file in the directory.

=item *

The file name is identical with the directory name, 
except for one changed or removed
suffix-word. (*.tar.gz -> *.tar; or *.tgz -> *.tar) 

=item *

The file must not already exist in the parent directory.

=back

C<unpack> prepares 20 empty subdirectory levels and chdirs the unpacker 
in there. This number can be adjusted using C<< new(dot_dot_safeguard => 20) >>.
A directory 20 levels up from the current working dir has mode 0 while 
the mime-handler runs. C<unpack> can optionally chmod(0) the parent of the subdirectory 
after it chdirs the unpacker inside. Use C<< new(jail_chmod0 => 1) >> for this, default 
is off. If enabled, a mime-handler trying to place files outside of the specified
destination_path may receive 'permission denied' conditions. 

These are special hacks to keep badly constructed 
tar-balls, cpio-, or zip-archives at bay.

Please note, that this can help against archives containing relative paths 
(like starting with '../../../foo'), but will be ineffective with absolute paths 
(starting with '/foo').
It is the responsibility of mime-handlers to not create absolute paths;
C<unpack> should not be run as the root user, to minimize the risk of
compromising the root filesystem.

A missing mime-handler is skipped, and subsequent handlers may take effect. A
mime-handler is expected to return an exit status of 0 upon success. If it runs
into a problem, it should print lines
starting with the affected filenames to stderr.
Such errors are recorded in the log with the unpacked archive, and as far as
files were created, also with these files.

Symbolic links are ignored while unpacking.

=cut

sub unpack
{
  ## as long as $archive is outside $self->{destdir}, we construct our destdir by
  ## replacing $self->{input_dir} with $self->{destdir}.
  ## This $self->{input_dir} must be created and kept constant at the earliest 
  ## possible call.
  ## When the $archive is inside $self->{destdir}, we do not use $self->{input_dir},
  ## we then use the current $in_dir as destdir.
  ## 
  ## Whenever an archive path outside $self->{destdir} is found, 
  ## it is first passed through Cwd::fast_abs_path before any other processing occurs.
  ##
  my ($self, $archive, $destdir) = @_;
  $destdir = $self->{destdir} unless defined $destdir;

  $destdir = $1 if $destdir =~ m{^(.*)$}s;	# brute force untaint

  unless (-e $archive)
    {
      push @{$self->{error}}, "unpack('$archive'): no such file or directory";
      return 1;
    }

  if (($self->{recursion_level}||0) > $RECURSION_LIMIT)
    {
      push @{$self->{error}}, "unpack('$archive','$destdir'): recursion limit $RECURSION_LIMIT";
      ## this is only an emergency stop.
      return 1;
    }

  if ($archive !~ m{^/} or $archive !~ m{^\Q$self->{destdir}\E/})
    {
      $archive = Cwd::fast_abs_path($archive) if -e $archive;
    }

  my $start_time = time;
  if ($self->{recursion_level}++ == 0)
    {
      $self->{json} ||= JSON->new()->ascii(1);

      $self->{input} = $archive;
      $self->{progress_tstamp} = $start_time;
      ($self->{input_dir}, $self->{input_file}) = ($1, $2) if $archive =~ m{^(.*)/([^/]*)$};

      my $s = $self->{json}->encode({destdir=>$self->{destdir}, pid=>$$, version=>$VERSION, 
		    input => $archive, start => scalar localtime});
      $s =~ s@}$@, "unpacked":{\n@;
      $self->log($s);
    }

  die "internal error" unless $self->{input_dir};

  my ($in_dir, $in_file) = ('/', '');
     ($in_dir, $in_file) = ($1, $2) if $archive =~ m{^(.*/)([^/]*)$};

  my $inside_destdir = 1;
  my $subdir = $in_dir; # remainder after stripping $orig_archive_prefix / $self->{destdir}
  unless ($subdir =~ s{^\Q$self->{destdir}\E/+}{})
    {
      $inside_destdir = 0;
      die "$archive path escaped. Neither inside original $self->{input_dir} nor inside destdir='$self->{destdir}'\n"
        unless $subdir =~ s{^\Q$self->{input_dir}\E/+}{};
    }

  print STDERR "unpack: r=$self->{recursion_level} in_dir=$in_dir, in_file=$in_file, destdir=$destdir\n" if $self->{verbose} > 1;

  my @missing_unpacker;

  if ($self->{progress_tstamp} + 10 < $start_time)
    {
      printf "T: %d files ...\n", $self->{file_count};
      $self->{progress_tstamp} = $start_time;
    }

  if (-d $archive)
    {
      $self->_chmod_add($archive, 0700, 0500);
      if (opendir DIR, $archive)
        {
          my @f = sort grep { $_ ne '.' && $_ ne '..' } readdir DIR;
	  closedir DIR;
	  print STDERR "dir = @f\n" if $self->{verbose} > 1;
	  for my $f (@f) 
	    {
	      next if $self->{exclude}{re} && $f =~ m{$self->{exclude}{re}};
	      my $new_in =  "$archive/$f";
	      ## if $archive is $inside_destdir, then $archive is normally indentical to $destdir.
	      ## ($inside_destdir means inside $self->{destdir}, actually)
	      my $new_destdir = $destdir; $new_destdir .= "/$f" if -d $new_in;
	      $self->unpack($new_in, $new_destdir) unless -l $new_in;
              $self->{progress_tstamp} = time;
	    }
	}
      else
        {
	  push @{$self->{error}}, "unpack dir ($archive) failed: $!";
	}
    }
  elsif (-f $archive)
    {
      if ($self->_not_excluded($subdir, $in_file) and
          !defined($self->{done}{$archive}))
	{
          $self->_chmod_add($archive, 0400);
	  my $m = $self->mime($archive);
	  my ($h, $more) = $self->find_mime_handler($m);
	  my $data = { mime => $m->[0] };
	  if ($more)
	    {
	      $data->{found} = $more;
	      push @missing_unpacker, @{$more->{missing}} if $more->{missing};
	    }

          if ($m->[0] eq 'text/plain' or !$h)
	    {
	      unless ($archive =~ m{^\Q$self->{destdir}\E/})
		{
		  mkpath($destdir);
		  my $destdir_in_file;
		     $destdir_in_file = $1 if "$destdir/$in_file" =~ m{^(.*)$}s; # brute force untaint

		  if (-e "$destdir_in_file")
		    {
		      print STDERR "unpack copy in: $destdir_in_file already exists, " if $self->{verbose};
		      $destdir = File::Temp::tempdir($TMPDIR_TEMPL, DIR => $destdir);
		      $destdir_in_file = $1 if "$destdir/$in_file" =~ m{^(.*)$}s; # brute force untaint
		      print STDERR "using $destdir_in_file instead.\n" if $self->{verbose};
		    }
		  $data->{error} = "copy($archive): $!" unless File::Copy::copy($archive, $destdir_in_file);
	          $self->logf($destdir_in_file => $data);
		}
	      else
	        {
	          $self->logf($archive => $data);
		}
	      $self->{file_count}++;
	    }
	  else
	    {
	      mkpath($destdir);
	      $self->{configdir} = $self->_prep_configdir() unless exists $self->{configdir};
	      my $new_name = $in_file;
	      
	      # Either shorten the name from e.g. foo.txt.bz2 to foo.txt or append 
	      # something: foo.pdf to foo.pdf._;
	      # Normally a suffix is appended by '.', but we also see '-' or '_' in real life.
	      unless ($h->{suffix_re} and $new_name =~ s{[\._-]$h->{suffix_re}(?:\._\d*)?$}{}i)
	        {
		  # avoid unary notation of recursion couning. There may be a 256 char limit per 
		  # directory entry. Start counting in decimal, if two or more.
		  # Hmm, the /e modifier is not mentioned in perlre, but it works. Is it deprecated??
	          $new_name .= "._";
	          $new_name =~ s{\._\._$}{\._2};
	          $new_name =~ s{\._(\d+)\._$}{ "._".($1+1) }e;
		}

	      ## if consumer of logf wants to do progress indication himself, 
	      ## then tell him what we do before we start. (Our timer tick code may be analternative...)
	      #
	      # if ($archive =~ m{^\Q$self->{destdir}\E})
	      #   {
	      #     $self->logf($archive => { unpacking => $h->{fmt_p} });
	      #   }
	        
	      my $unpacked = $self->_run_mime_handler($h, $archive, $new_name, $destdir, 
	      				$m->[0], $m->[2], $self->{configdir});

	      if (ref $unpacked)
	        {
		  $data->{failed} = $h->{fmt_p};
		  $data->{error} = $unpacked->{error};
		  $self->logf($archive => $data);
		  $self->{file_count}++;
		}
	      elsif ($unpacked eq "$destdir/$new_name" and 
	             readlink($unpacked)||'' eq $archive)
	        {
		  # a symlink backwards means, there is nothing to unpack here. take it as is.
		  unlink $unpacked;
		  $data->{passed} = $h->{name};

		  if ($archive =~ m{^\Q$self->{destdir}\E})
		    {
		      # if inside, we just flag it done and log it.
		      $self->{done}{$archive} = $archive;
		      $self->logf($archive => $data);
		    }
		  else
		    {
		      # if outside, we copy it in, flag it done there, and log it here.
		      if (File::Copy::copy($archive, $unpacked))
		        {
		          $self->{done}{$archive} = $unpacked;
			  $self->logf($unpacked => $data);
			}
		      else
		        {
		          $data->{error} = "copy($archive, $unpacked): $!";
			  $self->logf($archive => $data);
			}
		    }
		  $self->{file_count}++;
		}
	      else
		{
		  if ($archive =~ m{^\Q$self->{destdir}\E})
		    {
		      $self->{done}{$archive} = $unpacked;

		      # to delete it, we should know if it was created during unpack.
		      $data->{cmd} = $h->{fmt_p};
		      $data->{unpacked} = $unpacked;
		      $self->logf($archive => $data);
		      $self->{file_count}++;
		    }

		  my $newdestdir = $unpacked;
		  $newdestdir =~ s{/+[^/]+}{} unless -d $newdestdir;	        # make sure it is a directory
		  $newdestdir = $destdir unless $newdestdir =~ m{^\Q$self->{destdir}\E/};	# make sure it does not escape
		  if ($self->{one_shot})
		    {
		      local $self->{mime_orcish};
		      local $self->{mime_handler};

		      $self->unpack($unpacked, $newdestdir);
		    }
		  else
		    {
		      $self->unpack($unpacked, $newdestdir);
		    }
                  $self->{progress_tstamp} = time;
		}
	    }
	}
    }
  else
    {
      $self->logf($archive => { "skipped" => "special file"});
      $self->{file_count}++;
    }

  if (--$self->{recursion_level} == 0)
    {
      my $epilog = {end => scalar localtime, sec => time-$start_time };
      $epilog->{missing_unpacker} = \@missing_unpacker if @missing_unpacker;
      my $s = $self->{json}->encode($epilog);
      # a dummy entry at the end, to compensate for the trailing comma
      $s =~ s@^{@"/":{}},@;
      $self->log($s . "\n");

      if ($self->{lfp} ne $self->{logfile})
        {
          close $self->{lfp} or carp "logfile write ($self->{logfile}) failed: $!\n";
	}
      delete $self->{lfp};
      delete $self->{lfp_printed};
    }

  # FIXME: should return nonzero if we had any unrecoverable errors.
  return $self->{error} ? 1 : 0;
}

sub _chmod_add
{
  my ($self, $file, @modes) = @_;
  $file = $1 if $file =~ m{^(.*)$}m;
  my $perm = (stat $file)[2] & 07777;
  for my $m (@modes)
    {
      chmod($perm|$m, $file);	# may or may not succeed. Harmless here.
    }
}

=head2 run

$u->run([argv0, ...], @redir, ... { init => sub ..., in, out, err, watch, every, prog, ... })

A general purpose fork-exec wrapper, based on IPC::Run. STDIN is closed, unless you specify
an C<< in => >> as described in IPC::Run. STDERR and STDOUT are both printed to
STDOUT, prefixed with 'E: ' and 'O: ' respectively, unless you specify C<< out => >>,
C<< err => >>, or C<< out_err => >> ... for both.  

Using redirection operators in @redir takes precedence over the above in/out/err 
redirections. See also L<IPC::Run>. If you use the options in/out/err, you should
restrict your redirection operators to the forms '<', '0<', '1>', '2>', or '>&' due
to limitations in the precedence logic. Piping via '|' is properly recognized, 
but background execution '&' may confuse the precedence logic.

This C<run> method is completly independent of the rest of File::Unpack. It works both
as a static function and as a method call.
It is used internally by C<unpack>, but is exported to be of use elsewhere.

Init is run after construction of redirects. Calling chdir() in init thus has no
effect on redirects with relative paths. 

Return value in scalar context is the first nonzero result code, if any. In list context 
all return values are returned.
=cut

sub run
{
  shift if ref $_[0] ne 'ARRAY';	# toss $self object handle.
  my (@cmd) = @_;
  my $opt;
     $opt = pop @cmd if ref $cmd[-1] eq 'HASH';

  my $cmdname = $cmd[0][0]; $cmdname =~ s{^.*/}{};

  # run the command with 
  # - STDIN closed, unless you specify an { in => ... }
  # - STDERR and STDOUT printed prefixed with 'E: ', 'O: ' to STDOUT, 
  #   unless you specify out =>, err =>, or out_err => ... for both.
  $opt->{in}  ||= \undef;
  $opt->{out} ||= $opt->{out_err};
  $opt->{err} ||= $opt->{out_err};
  $opt->{out} ||= sub { print "O: ($cmdname) @_\n"; };
  $opt->{err} ||= sub { print "E: ($cmdname) @_\n"; };

  my $has_i_redir = 0; 
  my $has_o_redir = 0;
  my $has_e_redir = 0;

  ## The ugly truth is, there might be multiple commands with pipes.
  ## We need to provide all of them with the proper redirects.
  ## A command that pipes somewhere else, has_o_redir outbound through the pipe.
  ## A command that is piped into, has_i_redir inbound from the pipe.
  my @run = ();
  push @run, debug => $opt->{debug} if $opt->{debug};


  for my $c (@cmd)
    {
      if (ref $c)
        {
          push @run, $c;

          # put init early, so that it is run, before any IO redirects access relative paths.
          push @run, init => $opt->{init} if $opt->{init};
          next;		# don't look into argvs, but
	}
      # look only into redirection operators
      $has_i_redir++ if $c =~ m{^0?<};
      $has_o_redir++ if $c =~ m{^1?>};
      $has_e_redir++ if $c =~ m{^(?:2>|>&$)};
      if ($c eq '|')
        {
          push @run, '0<', $opt->{in} unless $has_i_redir;
	  $has_i_redir = 'piped';
          push @run, "2>", $opt->{err} unless $has_e_redir;
	  $has_e_redir = $has_o_redir = 0;
	}
      push @run, $c;	# $1 if $c =~ m{^(.*)$}s;	# brute force untaint
    }

  push @run, '0<', $opt->{in}  unless $has_i_redir;
  push @run, "1>", $opt->{out} unless $has_o_redir;
  push @run, "2>", $opt->{err} unless $has_e_redir;

# die Dumper \@run if $cmd[0][0] eq '/usr/bin/rpm2cpio';

  my $t;
     $t = IPC::Run::timer($opt->{every}-0.6) if $opt->{every};
  push @run, $t if $t;

  $run[0][0] = $1 if $run[0][0] =~ m{^(.*)$}s;
  my $h = eval { IPC::Run::start @run; };
  return wantarray ? (undef, $@) : undef unless $h;

  while ($h->pumpable)
    {
      # eval {} guards against 'process ended prematurely' errors.
      # This happens on very fast commands, despite pumpable().
      eval { $h->pump };
      if ($t && $t->is_expired)
        {
	  $t->{has_fired}++;
	  $opt->{prog}->($h, $opt);
	  $t->start($opt->{every});
	}
    }
  $h->finish;
  $opt->{finished} = 1;

  ## call it once more, to get the 100% printout, or somthing else...
  $opt->{prog}->($h, $opt) if $t->{has_fired};

  return wantarray ? $h->full_results : $h->result;
}

=head2 fmt_run_shellcmd

File::Unpack::fmt_run_shellcmd( $m->{argvv} )

Static function to pretty print the return value $m of method find_mime_handler();
It formats a command array used with run() as a properly escaped shell command string.

=cut 

sub _my_shell_quote
{
  my @a = @_;
  my $sub;
  $sub = '\\&_locate_tar'    if $a[0] eq \&_locate_tar;
  $sub = '\\&_locate_cpio_i' if $a[0] eq \&_locate_cpio_i;

  if ($sub)
    {
      shift @a;
      return "$sub " . shell_quote(@a);
    }
  return shell_quote(@a);
}

sub fmt_run_shellcmd
{
  my @a = @_;
  @a = @{$a[0]{argvv}} if ref $a[0] eq 'HASH';
  my @r = ();
  for my $a (@a)
    {
      push @r, ref($a) ? '('._my_shell_quote(@$a).')' : _my_shell_quote($a);
    }
  my $r = join ' ', @r;
  $r =~ s{^\((.*)\)$}{$1} unless $#a;	# parenthesis around a single cmd are unneeded.
  return $r;
}

## not a method, officially.
#
## Chdir in and out of a jail is done here, as IPC::Run::run({init}->())
## has bad timing for our purposes.
#
## fastjar extracts happily to ../../..
## this happens in cups-1.2.1/scripting/java/cups.jar
#
## FIXME:
# "/tmp/xxxx/cups-1.2.4-11.5.1.el5/cups-1.2.4/scripting/java/cups.jar":
#  {"cmd":"/usr/bin/unzip -P no_pw -q -o '%(src)s'",
#   "unpacked":"/tmp/xxxx/cups-1.2.4-11.5.1.el5/cups-1.2.4/_Knw_"}
# Two issues: 
#   a) _run_mime_handler in /tmp/xxxx/cups-1.2.4-11.5.1.el5/cups-1.2.4
#      should be /tmp/xxxx/cups-1.2.4-11.5.1.el5/cups-1.2.4/scripting/java
#   b) _Knw_ should never appear in the end result ...
#

sub _run_mime_handler
{
  my ($self, $h, @argv) = @_;

  for my $i (0..$#argv)
    {
      $argv[$i] = $1 if $argv[$i] =~ m{^(.*)$}s;	# brute force untaint
    }

  my $destdir = $argv[2];
  my $dot_dot_safeguard = $self->{dot_dot_safeguard}||0;
  $dot_dot_safeguard = 2 if $dot_dot_safeguard < 2;

  mkpath($destdir);
  my $jail_base = File::Temp::tempdir($TMPDIR_TEMPL, DIR => $destdir);
  my $jail = $jail_base . ("/_" x $dot_dot_safeguard);
  mkpath($jail);

  my $args = 
    {
      src	=> $argv[0],	# abs_path()
      destfile	=> $argv[1],	# filename() - a suggested name, simply based on src, in case the unpacker needs it.
      destdir	=> $jail,	# abs_path() - for now...
      mime	=> $argv[3],
      descr	=> $argv[4],	# mime_descr
      configdir	=> $argv[5]	# abs_path()
    };
  die "src must be an abs_path." unless $args->{src} =~ m{^/};
  
  my @cmd;
  for my $a (@{$h->{argvv}})
    {
      if (ref $a)
        {
	  my @c = ();
	  for my $b (@$a)
	    {
	      push @c, _subst_args($b, $args);
	    }
	  push @cmd, [@c];
	}
      else
        {
	  push @cmd, _subst_args($a, $args);
	}
    }
  print STDERR "_run_mime_handler in $destdir: " . fmt_run_shellcmd(@cmd) . "\n" if $self->{verbose} > 1;

  my $cwd = getcwd() or carp "cannot fetch initial working directory, getcwd: $!";
  $cwd = $1 if $cwd =~ m{^(.*)$}s;	#  brute force untaint. Whereever you go, there you are.
  chdir $jail or die "chdir '$jail'";
  chmod 0, $jail_base if $self->{jail_chmod0};
  # Now have fully initialzed in the parent before forking. 
  #  This is needed, as all redirect operators are executed in the parent before forking.
  # init => sub { ... } is no longer needed. sigh, I really wanted to the init sub for the chdir.
  # But hey, mkpath() and rmtree() change the cwd so often, and restore it, so why shouldn't we?


  my @r = $self->run(@cmd, 
    { 
      debug => ($self->{verbose} > 2) ? $self->{verbose} - 2 : 0, 
      watch => $args->{src}, every => 5, fu_obj => $self, mime_handler => $h, 
      prog => sub 
{
  $_[1]{tick}++; 
  my $name = $_[1]{watch}; $name =~ s{.*/}{};
  if ($_[1]{finished})
    {
      printf "T: %s (%s,  done)\n", $name, _unit_bytes(-s $_[1]{watch},1);
    }
  elsif (my $p = _children_fuser($_[1]{watch}, POSIX::getpid()))
    {
      _fuser_offset($p);
      # we may get muliple process with multiple filedescriptors.
      # select the one that moves fastest. 
      my $largest_diff = -1;
      for my $pid (keys %$p)
        {
	  for my $fd (keys %{$p->{$pid}{fd}})
	    {
	      my $diff = ($p->{$pid}{fd}{$fd}{pos}||0) - ($_[1]{fuser}{$pid}{fd}{$fd}{pos}||0);
	      if ($diff > $largest_diff)
	        {
		  $largest_diff = $diff;
		  $p->{fastest_fd} = $p->{$pid}{fd}{$fd};
		}
	    }
	}
      # Stick with the one we had before, if none moves.
      $p->{fastest_fd} = $_[1]{fuser}{fastest_fd} if $largest_diff <= 0;
      $_[1]{fuser} = $p;
      my $off = $p->{fastest_fd}{pos}||0;
      my $tot = $p->{fastest_fd}{size}||(-s $_[1]{watch})||1;
      printf "T: %s (%s, %.1f%%)\n", $name, _unit_bytes($off,1), ($off*100)/$tot;
    }
  else
    {
      print "T: $name tick_tick $_[1]{tick}\n"; 
    }
},
    });
    
  chmod 0700, $jail_base if $self->{jail_chmod0};
  chdir $cwd or die "cannot chdir back to cwd: chdir($cwd): $!";

  # TODO: handle failure
  # - remove all, 
  # - retry with a fallback handler , if any.
  print STDERR "Non-Zero return value: $r[0]\n" if $r[0];

  # FIXME: we should not die here
  die "run() failed:\n " . fmt_run_shellcmd(@cmd) . "\n" . Dumper \@r if $r[1];

  # loop through all _: if it only contains one item , replace it with this item,
  # be it a file or dir. This uses $jail_tmp, an unused pathname.
  my $jail_tmp = File::Temp::tempdir($TMPDIR_TEMPL, DIR => $destdir);
  rmdir $jail_tmp;

  # if only one file in $jail, move it up, and return 
  # the filename instead of the dirname here.
  # (We don't search for $args->{destfile}, it is the unpackers choice to use it or not.)
  my $wanted_name;
  for (my $i = 0; $i <= $dot_dot_safeguard; $i++)
    {
      opendir DIR, $jail_base or last;
      my @found = grep { $_ ne '.' and $_ ne '..' } readdir DIR;
      closedir DIR;
      my $found0;
         $found0 = $1 if defined($found[0]) and $found[0] =~ m{^(.*)$}s;	# brute force untaint
      print STDERR "dot_dot_safeguard=$dot_dot_safeguard, i=$i, found=$found0\n" if $self->{verbose} > 2;
      unless (@found)
        {
	  rmdir $jail_base;
	  my $name;
	     $name = $1 if $args->{src} =~ m{/([^/]+)$};
          print STDERR "oops(i=$i): nothing unpacked?? Adding $name as is.\n" if $self->{verbose};
	  return { error => "nothing unpacked" };
	}
      last if scalar @found != 1;
      $wanted_name = $found0 if $i == $dot_dot_safeguard;
      last unless -d $jail_base . "/" . $found0;
      rename $jail_base, $jail_tmp;
      rename $jail_tmp . "/" . $found0, $jail_base;
      rmdir $jail_tmp or last;
    }

  ## this message is broken.
  # print STDERR "Hmmm, unpacker did not use destname: $args->{destfile}\n" if $self->{verbose} and !defined $wanted_name;

  print STDERR "Hmmm, unpacker saw destname: $args->{destfile}, but used destname: $wanted_name\n" 
    if $self->{verbose} and defined($wanted_name) and $wanted_name ne $args->{destfile};

  $wanted_name = $args->{destfile} unless defined $wanted_name;
  my $wanted_path;
     $wanted_path = $destdir . "/" . $wanted_name if defined $wanted_name;

  if (defined($wanted_name) and -e $wanted_path)
    {
      ## try to come up with a very similar name, just different suffix.
      ## be compatible with path name shortening in unpack()
      my $test_path = $wanted_path . '._';
      for my $i ('', 1..9)
        {
	  # All our mime detectors work on file contents, rather than on suffixes.
	  # Thus messing with the suffix should be okay here.
	  unless (-e $test_path.$i)
	    {
              $wanted_path = $test_path.$i;
	      last;
	    }
	}
    }

  my $unpacked = $jail_base;
  if (defined($wanted_name) and !-e $wanted_path)
    {
      if (-d $jail_base)
        {
	  ## find out, if the unpacker created exactly one file or one directory, 
	  ## in this case we can move one level further.
	  opendir DIR, $jail_base;
          my @found = grep { $_ ne '.' and $_ ne '..' } readdir DIR;
          closedir DIR;
          my $found0;
	     $found0 = $1 if defined($found[0]) and $found[0] =~ m{^(.*)$}s;	# brute force untaint

	  if ($#found == 0 and $found0 eq $wanted_name)
	    {
              rename "$jail_base/$found0", $wanted_path;
	      rmdir $jail_base;
	    }
	  else
	    {
              rename $jail_base, $wanted_path;
	    }
	}
      else
        {
          rename $jail_base, $wanted_path;
	}
      $unpacked = $wanted_path;
    }

  # catch some patholigical cases.
  if (-f $unpacked and !-l $unpacked)
    {
      if (!-s $unpacked)
        {
	  print STDERR "Ooops, only one empty file after unpacking???\n" if $self->{verbose};
	  unlink $unpacked; symlink $args->{src}, $unpacked;
	}
      elsif (-s $unpacked eq (my $s = -s $args->{src}))
	{
	  print STDERR "Hmm, same size ($s bytes) after unpacking???\n" if $self->{verbose};
	  ## xz -dc -f behaves like cat, if called on an unknown file.
	  ## Compare the files. If they are identical, stop this:
	  if (File::Compare::cmp($args->{src}, $unpacked) == 0)
	    {
	      print STDERR "Oops, identical after unpacking!\n" if $self->{verbose};
	      unlink $unpacked; 
	      symlink $args->{src}, $unpacked;
	    }
	}
    }

  return $unpacked;
}

sub _children_fuser
{
  my ($file, $ppid) = @_;
  $ppid ||= 1;
  $file = Cwd::abs_path($file);

  opendir DIR, "/proc" or die "opendir /proc failed: $!\n";
  my %p = map { $_ => {} } grep { /^\d+$/ } readdir DIR;
  closedir DIR;

  # get all procs, and their parent pids
  for my $p (keys %p)
    {
      if (open IN, "<", "/proc/$p/stat")
        {
	  # don't care if open fails. the process may have exited.
	  my $text = join '', <IN>;
	  close IN;
	  if ($text =~ m{\((.*)\)\s+(\w)\s+(\d+)}s)
	    {
	      $p{$p}{cmd} = $1;
	      $p{$p}{state} = $2;
	      $p{$p}{ppid} = $3;
	    }
	}
    }

  # Weed out those who are not in our family
  if ($ppid > 1)
    {
      for my $p (keys %p)
	{
	  my $family = 0;
	  my $pid = $p;
	  while ($pid)
	    {
	      # Those that have ppid==1 may also belong to our family. 
	      # We never know.
	      if ($pid == $ppid or $pid == 1)
		{
		  $family = 1;
		  last;
		}
	      last unless $p{$pid};
	      $pid = $p{$pid}{ppid};
	    }
	  delete $p{$p} unless $family;
	}
    }

  my %o; # matching open files are recorded here

  # see what files they have open
  for my $p (keys %p)
    {
      if (opendir DIR, "/proc/$p/fd")
        {
	  my @l = grep { /^\d+$/ } readdir DIR;
	  closedir DIR;
	  for my $l (@l)
	    {
	      my $r = readlink("/proc/$p/fd/$l");
	      next unless defined $r;
	      # warn "$p, $l, $r\n";
	      if ($r eq $file)
	        {
	          $o{$p}{cmd} ||= $p{$p}{cmd};
	          $o{$p}{fd}{$l} = { file => $file };
		}
	    }
	}
    }
  return \%o;
}

# see if we can read the file offset of a file descriptor, and the size of its file.
sub _fuser_offset
{
  my ($p) = @_;
  for my $pid (keys %$p)
    {
      for my $fd (keys %{$p->{$pid}{fd}})
        {
	  if (open IN, "/proc/$pid/fdinfo/$fd")
	    {
	      while (defined (my $line = <IN>))
	        {
		  chomp $line;
		  $p->{$pid}{fd}{$fd}{$1} = $2 if $line =~ m{^(\w+):\s+(.*)\b};
		}
	    }
	  close IN;
	  $p->{$pid}{fd}{$fd}{size} = -s $p->{$pid}{fd}{$fd}{file};
	}
    }
}


sub _prep_configdir
{
  my ($self) = @_;
  my $dir = "/tmp/file_unpack_$$/";
  mkpath($dir);
  my $j = $self->{json}->allow_nonref();

  open my $SH, ">", "$dir/config.sh";
  open my $JS, ">", "$dir/config.js";

  print $JS "{\n";

  for my $group ('', 'minfree', 'exclude')
    {
      my $h_ref = ($group eq '') ? $self : $self->{$group};
      for my $k (sort keys %$h_ref)
        {
	  my $val = $h_ref->{$k};
	  next if $k eq 'recursion_level';
	  next if ref $val;		# we only take scalars.
	  my $name = ($group eq '') ? $k : "${group}_$k";
	  printf $SH "%s=%s\n", shell_quote(uc "fu_$name"), shell_quote($val);
	  printf $JS "%s:%s,\n", $j->encode($name), $j->encode($val);
	}
    }

  print $SH "FU_VERSION=$VERSION\n";
  print $JS qq["fu_version":"$VERSION"\n}\n];

  close $SH;
  close $JS;
  return $dir;
}


=head2 mime_handler_dir mime_handler

$u->mime_handler_dir($dir, ...)
$u->mime_handler($mime_name, $suffix_regexp, \@argv, @redir, ...)

Registers one or more directories where external mime-helper programs are found.
The words helper and handler are used as synonyms here, helpers often refer to
external programs, where handlers refer to builtin shell commands. 
Multiple directories can be registered, They are searched in reverse order, i.e. 
last added takes precedence. Any external mime-handler takes precedence over built-in code.

The suffix_regexp is used to derive the destination name from the source name.
It is not used for selecting helpers.

Helpers are mapped to mime-types by their mime_name. The name can be constructed
from the mimetype by replacing the '/' with a '=' character, and by using the
word 'ANY' as a wildcard component. The '=' character is interpreted as an
implicit '=ANY+' if needed.

 Examples:

  Mimetype                   handler names tried from top to bottom
  -----------------------------------------------------------------
  image/png                  image=png 
                              image=ANY 
			       image
			        ANY=png
			         ANY=ANY
				  ANY

  application/vnd.oasis+zip  application=vnd.oasis+zip 
                              application=ANY+zip
                               application=ANYzip
			        application=zip
			         application=ANY
				      ...
  
A trailing '=ANY' is implicit, as shown by these examples. 
The rules for precedence are this:

=over 

=item *

Search in the latest directory is exhaused first, then the previously added directory is considered in turn,
up to all directories have been traversed, or until a matching helper is found.
 
=item *

A matching name with wildcards has lower precedence than a matching name without.

=item *

A wildcard before the '=' sign lowers precedence more than one after it.

=back

The mapping takes place when C<mime_handler_dir> is called. Adding helper scripts to a directory
afterwards has no effect. C<mime_handler> does not do any implicit expansions. Call it
multiple times with the same handler command and different names if needed.
The default argument list is "%(src)s %(destfile)s %(destdir)s %(mime)s %(descr)s %(configdir)s" --
this is applied, if no args are given and no redirections are given. See also C<unpack> for more semantics and how a handler should behave.

Both methods return an ARRAY-ref of HASHes describing all known (old and newly added) mime handlers.

=cut 
my @def_mime_handler_fmt = qw(%(src)s %(destfile)s %(destdir)s %(mime)s %(descr)s %(configdir)s);

sub _subst_args
{
  my $f = Text::Sprintf::Named->new({fmt => $_[0]});
  return $f->format({args => $_[1]});
}

sub mime_handler
{
  my ($self, $name, $suffix_re, @args) = @_;
  @args = ($name) unless @args;
  @args = ([@args]) unless ref $args[0];
  push @{$args[0]}, @def_mime_handler_fmt unless $#{$args[0]} or defined $args[1];

  # cut away the path prefix from name. And use / instead of = in the mime name.
  $name =~ s{(.*/)?(.*?)=(.*?)$}{$2=$3};

  unless ($name =~ m{[/=]})
    {
      print STDERR "mime_handler '$name' needs a '=' or '/'.\n" if $self->{verbose};
      return $self->{mime_handler};
    }

  my $pat = "^\Q$name\E\$";
  $pat =~ s{\\=}{/(?:x-|ANY\\+)?};
  $pat =~ s{\\%}{ANY}g;
  $pat =~ s{^\^ANY}{};
  $pat =~ s{ANY\$$}{};
  $pat =~ s{ANY}{\\b\[\^\/\]+\\b}g;
  unshift @{$self->{mime_handler}}, 
    { 
      name => $name, pat => $pat, suffix_re => $suffix_re, 
      fmt_p => fmt_run_shellcmd(@args), argvv => \@args
    };

  delete $self->{mime_orcish};	# to be rebuilt in find_mime_handler()

  return $self->{mime_handler};
}

=head2 list

Returns an ARRAY of preformatted patterns and mime-handlers.

Example:

  printf @$_ for $u->list(); 

=cut

sub list
{
  my ($self) = @_;

  my $width = 10;
  for my $m (@{$self->{mime_handler}})
    {
      $width = length($m->{pat}) if length($m->{pat}) > $width;
    }

  my @r;
  for my $m (@{$self->{mime_handler}})
    {
      push @r, [ "%-${width}s %s\n", $m->{pat}, $m->{fmt_p} ];
    }
  return @r;
}

sub mime_handler_dir
{
  my ($self, @dirs) = @_;

  for my $d (@dirs)
    {
      my %h;
      if (opendir DIR, $d)
        {
	  %h = map { $_ => { a => "$d/$_" } } grep { -f "$d/$_" } readdir DIR;
	  closedir DIR;
	}
      else
        {
	  carp "Cannot opendir $d: $!, skipped\n";
	}

      # add =ANY suffix, if missing
      for my $h (keys %h)
        {
	  if ($h !~ m{[/=]})
	    {
	      my $h2 = $h . "=ANY";
	      $h{$h2} = { %{$h{$h}} } unless defined $h{$h2};
	    }
	}

# not needed, this is implicit in mime_handler()/$pat
#
#      # add expansion of = to =ANY+, if missing
#      for my $h (keys %h)
#        {
#	  next if $h =~ m{=ANY+};
#	  my $h2 = $h; $h2 =~ s{=}{=ANY+};
#	  $h{$h2} = $h{$h} unless defined $h{$h2};
#	}

      # calculate priorities
      for my $h (keys %h)
        {
	  my $n = 1000000;
	  my $p = 1000;
	  while ($h =~ m{(ANY|=)}g)
	    {
	      if ($1 eq '=')
	        {
		  $n = 1000;
		}
	      else
	        {
	          $p += $n;
		}
	    }
	  # longer length has prio over shorter length. Hmm, this is ineffective, isnt it?
	  $h{$h}{p} = $p - length($h);
	}

      # Now push them, sorted by prio.
      # Smaller prio_number is better. Later addition is prefered.
      for my $h (sort { $h{$b}{p} <=> $h{$a}{p} } keys %h)
        {
	  # do not ruin the original name by resolving symlinks and such.
	  $self->mime_handler($h, undef, [Cwd::fast_abs_path($h{$h}{a})]);
	}
    }
  return $self->{mime_handler};
}

=head2 find_mime_handler

$u->find_mime_handler($mimetype)

Returns a mime-handler suitable for unpacking the given $mimetype.
If called in list context, a second return value indicates which 
mime handlers whould be suitable, but could not be found in the system.

=cut

sub find_mime_handler
{
  my ($self, $mimetype) = @_;
  $mimetype = $mimetype->[0] if ref $mimetype eq 'ARRAY';

  return $self->{mime_orcish}{$mimetype}
    if defined $self->{mime_orcish}{$mimetype} and 
            -f $self->{mime_orcish}{$mimetype}{argvv}[0][0];
  
  my $r = undef;
  for my $h (@{$self->{mime_handler}})
    {
      if ($mimetype =~ m{$h->{pat}})
        {
	  $self->_finalize_argvv($h);
	  unless (-f $h->{argvv}[0][0])
	    {
	      push @{$r->{missing}}, $h->{argvv}[0][0];
	      next;
	    }
	  $self->{mime_orcish}{$mimetype} = $h;
	  return wantarray ? ($h, $r) : $h;
	}
    }
  return wantarray ? (undef, $r) : undef;
}

#
# _finalize_argvv() executes a sub in 3 places:
# The argvv ptr itself can be a sub: 
#   this should return an array, where the
#   first element is the command (as an array-ref) and subsequent elements are
#   redirects. See run() for details.
# One of the argvv elements is a sub:
#   this should return the command as an array-ref, if it is argvv[0],
#   or return one or more redirects.
# One element of argvv[0] is a sub:
#   this should return one or more command names, options, arguments,
#
# Tricky part of the implementation is the in-place array expansion while iterating.
#
sub _finalize_argvv
{
  my ($self, $h) = @_;

  my $update_fmt_p = 0;
  if (ref $h->{argvv} eq 'CODE')
    {
      $h->{argvv} = [ $h->{argvv}->($self) ];
      $update_fmt_p++;
    }

  # If any part of LIST is an array, "foreach" will get very confused if you add or
  # remove elements within the loop body, for example with "splice".   So don't do
  # that.
  # Sigh, we want do do exactly that, a sub may replace itself by any number of elements. Use booring C-style loop.
  my $last = $#{$h->{argvv}};
  for (my $idx = 0; $idx <= $last; $idx++)
    {
      if (ref $h->{argvv}[$idx] eq 'CODE')
        {
	  my @r = $h->{argvv}[$idx]($self);
	  splice @{$h->{argvv}}, $idx, 1, @r;
	  $idx += $#r;
	  $last +=$#r;
          $update_fmt_p++;
	}
    }
  $last = $#{$h->{argvv}};
  for (my $idx = 0; $idx <= $last; $idx++)
    {
      next unless ref $h->{argvv}[$idx] eq 'ARRAY';
      my $last1 = $#{$h->{argvv}[$idx]};
      for (my $idx1 = 0; $idx1 <= $last1; $idx1++)
        {
	  if (ref $h->{argvv}[$idx][$idx1] eq 'CODE')
	    {
	      my @r = $h->{argvv}[$idx][$idx1]->($self);
	      splice @{$h->{argvv}[$idx]}, $idx1, 1, @r;
	      $idx1 += $#r;
	      $last1 +=$#r;
              $update_fmt_p++;
	    }
	}
    }

  $h->{fmt_p} = fmt_run_shellcmd($h) if $update_fmt_p;
}

=head2 minfree

$u->minfree(factor => 10, bytes => '100M', percent => '3%', warning => sub { .. })

THESE TESTS ARE TO BE IMPLEMENTED.

Guard the filesystem (destdir) against becoming full during C<unpack>. 
Before unpacking each source archive, the free space is measured and compared against three conditions:

=over 

=item *

The archive size multiplied with the given factor must fit into the filesystem.

=item *

The given number of bytes (in optional K, M, G, or T units) must be free.

=item *

The filesystem must have at least the given free percentage. The '%' character is optional.
 
=back

The warning method is called if any of the above conditions fail. Its signature is: 
  &warning->($pathname, $full_percentage, $free_bytes, $free_inodes);
It is expected to print an appropriate warning message, and delay a few seconds.
It should return 0 to cause a retry. It should return nonzero to continue unpacking.
The default warning method prints a message to STDERR, waits 30 seconds, and returns 0.

The filesystem may still become full and unpacking may fail, if e.g. factor was chosen lower than 
the average compression ratio of the archives.

=cut

sub _bytes_unit
{
  my ($text) = @_;
  return int($1*1024)                if $text =~ m{([\d\.]+)k}i;
  return int($1*1024*1024)           if $text =~ m{([\d\.]+)m}i;
  return int($1*1024*1024*1024)      if $text =~ m{([\d\.]+)g}i;
  return int($1*1024*1024*1024*1024) if $text =~ m{([\d\.]+)t}i;
  return int($text);
}

sub _unit_bytes
{
  my ($number, $dec_places) = @_;
  $dec_places = 2 unless defined $dec_places;
  my $div = 1;
  my $unit = '';
  my $neg = '';
  if ($number < 0)
    {
      $neg = '-'; $number = -$number;
    }
  if ($number > $div * 1024)
    {
      $div *= 1024; $unit = 'k'; 
      if ($number > $div * 1024)
        {
	  $div *= 1024; $unit = 'm'; 
	  if ($number > $div * 1024)
	    {
	      $div *= 1024; $unit = 'g'; 
	      if ($number > $div * 1024)
	        {
		  $div *= 1024; $unit = 't'; 
		}
	    }
	}
    }
  return sprintf "%s%.*f%s", $neg, $dec_places, ($number / $div), $unit;
}

# see fs.pm/check_fs_health()

sub minfree
{
  my $self = shift;
  my %opt = @_;

  for my $i qw(factor bytes percent)
    {
      $self->{minfree}{$i} = $opt{$i} if defined $opt{$i};
      $self->{minfree}{$i} ||= 0;
    }
  $self->{minfree}{bytes} = _bytes_unit($self->{minfree}{bytes});
  $self->{minfree}{percent} =~ s{%$}{};
  $self->{fs_warn} = $opt{warning} if ref $opt{warning};
}

=head2 mime

$u->mime($filename)

$u->mime(file => $filename)

$u->mime(buf => "#!/bin ...", file => "what-was-read")

$u->mime(fd => \*STDIN, file => "what-was-opened")

Determines the mimetype (and optionally additional information) of a file.
The file can be specified by filename, by a provided buffer or an opened filedescriptor.
For the latter two cases, specifying a filename is optional, and used only for diagnostics.

C<mime> uses libmagic by Christos Zoulas exposed via File::LibMagic and also uses
the shared-mime-info database from freedesktop.org exposed via
File::MimeInfo::Magic, if available.  Either one is sufficient, but having both
is better. LibMagic sometimes says 'text/x-pascal', although we have a F<.desktop>
file, or says 'text/plain', but has contradicting details in its description.

C<File::MimeInfo::Magic::magic> is consulted where the libmagic output is dubious. E.g. when 
the desciption says something interesting like 'Debian binary package (format 2.0)' but the 
mimetype says 'application/octet-stream'. The combination of both libraries gives us 
excellent reliability in the critical field of mime-type recognition.

This implementation also features multi-level mime-type recognition for efficient unpacking.
When e.g. unpacking a large bzipped tar archive, this saves us from creating a
huge temporary tar-file which C<unpack> would extract in a second step.  The multi-level recognition
returns 'application/x-tar+bzip2' in this case, and allows for a mime-handler
to e.g. pipe the bzip2 contents into tar (which is exactly what 'tar jxvf'
does, making a very simple and efficient mime-handler).

C<mime> returns a 3 or 4 element arrayref with mimetype, charset, description, diff;
where diff is only present when the libfile and shared-mime-info methods disagree.

In case of 'text/plain', an additional rule based on file name suffix is used to allow
recognition of well known plain text pack formats. 
We return 'text/x-suffix-XX+plain', where XX is one of the recognized suffixes
(in all lower case and without the dot).  E.g. a plain mmencoded file has no
header and looks like 'plain/text' to all the known magic libraries. We
recognize the suffixes .mm, .b64, and .base64 for this (case insignificant).
A similar rule exitst for 'application/octect-stream'. It may trigger e.g. for
lzma compressed files which fail to provide a magic number.

Examples:
 
 [ 'text/x-perl', 'us-ascii', 'a /usr/bin/perl -w script text']

 [ 'text/x-mpegurl', 'utf-8', 'M3U playlist text', 
   [ 'text/plain', 'application/x-mpegurl']]

 [ 'application/x-tar+bzip2, 'binary', 
   "bzip2 compressed data, block size = 900k\nPOSIX tar archive (GNU)", ...]

=cut

sub mime 
{
  my ($self, @in) = @_;

  my %in;
     %in = %{$in[0]}  if !$#in and ref $in[0] eq 'HASH';
  unshift @in, 'file' if !$#in and !ref $in[0];
  %in = @in if $#in > 0;

  my $flm = $self->{flm} ||= File::LibMagic->new();

  unless (defined $in{buf})
    {
      my $fd = $in{fd};
      unless ($fd)
        {
	  open $fd, "<", $in{file} or
	    return [ 'x-system/x-error', undef, "cannot open '$in{file}': $!" ];
	}

      my $f = $in{file}||'-';
      $in{buf} = '';
      my $pos = tell $fd;
      ##bzip2 below needs a long buffer, or it returns 0.
      my $len = read $fd, $in{buf}, $UNCOMP_BUFSZ;
      return [ 'x-system/x-error', undef, "read '$f' failed: $!" ] unless defined $len;
      return [ 'x-system/x-error', undef, "read '$f' failed: $len: $!" ] if $len < 0;
      return [ 'text/x-empty', undef, 'empty' ] if $len == 0;
      seek $fd, $pos, 0;

      close $fd unless $in{fd};
    }


  ## flm can say 'cannot open \'IP\' (No such file or directory)'
  ## flm can say 'CDF V2 Document, corrupt: Can\'t read SAT'	(application/vnd.ms-excel)
  my $mime1 = $flm->checktype_contents($in{buf});
  if ($mime1 =~ m{, corrupt: } or $mime1 =~ m{^application/octet-stream\b})
    {
      # application/x-iso9660-image is reported as application/octet-stream if the buffer is short.
      # iso images usually start with 0x8000 bytes of all '\0'.
      print STDERR "mime: readahead buffer $UNCOMP_BUFSZ too short\n" if $self->{verbose} > 2;
      if (defined $in{file})
        {
          print STDERR "mime: reopening $in{file}\n" if $self->{verbose} > 1;
          $mime1 = $flm->checktype_filename($in{file});
	}
    }
  print STDERR "flm->checktype_contents: $mime1\n" if $self->{verbose} > 1;
  $in{file} = '-' unless defined $in{file};
    
  return [ 'x-system/x-error', undef, $mime1 ] if $mime1 =~ m{^cannot open};

  # in SLES11 we get 'text/plain charset=utf-8' without semicolon.
  my $enc; ($mime1, $enc) = ($1,$2) if $mime1 =~ m{^(.*?);\s*(.*)$} or
                                       $mime1 =~ m{^(.*?)\s+(.*)$};
  $enc =~ s{^charset=}{} if defined $enc;
  my @r = ($mime1, $enc, $flm->describe_contents($in{buf}) );
  my $mime2;

  if ($mime1 =~ m{^text/x-(?:pascal|fortran)$})
    {
      # xterm.desktop
      # ['text/x-pascal; charset=utf-8','UTF-8 Unicode Pascal program text']
      # 'application/x-desktop'
      #
      # Times-Roman.afm
      # ['text/x-fortran; charset=us-ascii','ASCII font metrics']
      # 'application/x-font-afm'
      #
      # debian/rules
      # ['text/x-pascal; charset=us-ascii','a /usr/bin/make -f  script text']
      # 'text/x-makefile'
      if ($mime2 ||= eval { open my $fd,'<',\$in{buf}; File::MimeInfo::Magic::magic($fd); })
        {
	  $r[0] = "text/$1" if $mime2 =~ m{/(\S+)};
	}
    }
  elsif (($mime1 eq 'text/plain' and $r[2] =~ m{(?:PostScript|font)}i)
	or ($mime1 eq 'application/postscript'))
    {
      # 11.3 says:
      #  IPA.pfa
      #  ['text/plain; charset=us-ascii','PostScript Type 1 font text (OmegaSerifIPA 001.000)']
      # sles11 says:
      #  IPA.pfa
      #  ['application/postscript', undef, 'PostScript document text']
      #
      # mime2 = 'application/x-font-type1'
      # $mime2 = eval { File::MimeInfo::Magic::mimetype($in{file}); };
      $mime2 ||= eval { open my $fd,'<',\$in{buf}; File::MimeInfo::Magic::magic($fd); };
      if ($mime2 and $mime2 =~ m{^(.*)/(.*)$})
        {
	  my ($a,$b) = ($1,$2);
	  $a = 'text' if $r[2] =~ m{\btext\b}i; 
	  $r[0] = "$a/$b";
	}
    }

  if ($r[0] eq 'text/plain' or 
      $r[0] eq 'application/octet-stream')
    {
      # hmm, are we sure? No, if the description contradicts:
      # 
      $r[0] = "text/x-uuencode" if $r[2] eq 'uuencoded or xxencoded text';

      # bin/floor
      # ['text/x-pascal; charset=us-ascii','a /usr/bin/tclsh script text']
      # 'text/plain'
      $r[0] = "text/x-$2" if $r[2] =~ m{^a (\S*/)?([^/\s]+) .*script text$}i;
      if ($r[2] =~ m{\bimage\b})
        {
	  # ./opengl/test.tga
	  # ['application/octet-stream; charset=binary','Targa image data - RGB 128 x 128']
	  # 'image/x-tga'
          $mime2 ||= eval { open my $fd,'<',\$in{buf}; File::MimeInfo::Magic::magic($fd); };
	  $r[0] = $mime2 if $mime2 and $mime2 =~ m{^image/};
	}
    }

  if ($r[0] eq 'application/octet-stream')
    {
      # it can't get much worse, can it?
      ##
      # dotdot.tar.lzma
      # {'File::MimeInfo::Magic' => 'application/x-lzma-compressed-tar'} -- no, that was suffix based!
      # {'File::LibMagic' => ['application/octet-stream; charset=binary','data']}
      $mime2 ||= eval { open my $fd,'<',\$in{buf}; File::MimeInfo::Magic::magic($fd); };
      #
      # File::LibMagic misreads monotone-0.99.1/monotone.info-1 as app/bin
      # File::MimeInfo::Magic::magic() returns undef for that one.
      # But perl itself does not agree:
      $mime2 ||= 'application/x-text-mixed' if -T $in{file};

      $r[0] = $mime2 if $mime2;
    }

  my $uncomp_buf = '';

  if ($r[0] eq 'application/octet-stream')
    {
      ## lzma is an extremly bad format. It has no magic.
      #
      # WARNING from Compress::unLZMA
      #  "This version only implements in-memory decompression (patches are welcomed).
      #   There is no way to recognize a valid LZMA encoded file with the SDK.
      #   So, in some cases, you can crash your script if you try to uncompress a
      #   non valid LZMA encoded file."
      # Does this also apply to us? 
      #
      # -- hmm, maybe we better leave it at calling lzcat.
      # Trade in "always a bit expensive" versus "sometimes crashing"...
      # 
#      my $lztest = `sh -c "/usr/bin/lzcat < $in{file} | head -c 1k > /dev/null" 2>&1`;
#      # -> /usr/bin/lzcat: (stdin): File format not recognized
#      if ($lztest !~ m{(not recognized|error)}i)
#        {
#	  $r[0] = 'application/x-lzma';
#	}

      if (10 < length $in{buf})
        {
	  no strict 'subs';	# Compress::Raw::Lzma::AloneDecoder, LZMA_OK, LZMA_STREAM_END

	  my $saved_input = $in{buf};
          my ($lz, $stat) = eval { Compress::Raw::Lzma::AloneDecoder->new(-Bufsize => $UNCOMP_BUFSZ, -LimitOutput => 1); };
	  if ($lz)
	    {
	      $stat = $lz->code($in{buf}, $uncomp_buf);
	      if (($stat == LZMA_OK or $stat == LZMA_STREAM_END) 
	      	  and 
	          (length($uncomp_buf) > length($saved_input)))
	        {
		  $r[0] = "application/x-lzma";
		  $r[2] = "LZMA compressed data, no magic";
		}
	      # This decompressor consumes the input.
	      $in{buf} = $saved_input;
	    }
	}
    }
  # printf STDERR "in-buf = %d bytes\n", length($in{buf});

  if ($r[0] =~ m{^application/(?:x-)?gzip$})
    {
      my ($gz, $stat) = eval { new Compress::Raw::Zlib::Inflate( -WindowBits => WANT_GZIP() ); };
      if ($gz)
        {
	  my $stat = $gz->inflate($in{buf}, $uncomp_buf);
	  # printf STDERR "stat=%s, uncomp=%d bytes \n", $stat, length($uncomp_buf);
	}
    }

  ## bzip2 is not nice for stacked mime checking. 
  ## It needs a huge input buffer that we do not normally provide.
  ## We only support it at the top of a stack, where we acquire enough additional 
  ## input until bzip2 is happy.
  if ($r[0] =~ m{^application/(?:x-)?bzip2$} && !$in{recursion})
    {
      my $limitOutput = 1;
      my ($bz, $stat) = eval { new Compress::Raw::Bunzip2 0, 0, 0, 0, $limitOutput; };
      if ($bz)
        {
	  ## this only works if this is a first level call.
	  open my $IN, "<", $in{file} unless $in{file} eq '-';
	  seek $IN, length($in{buf}), 0;
	  while (!length $uncomp_buf)
	    {
              my $stat = $bz->bzinflate($in{buf}, $uncomp_buf);
	      # $bz->bzflush($uncomp_buf);	# wishful thinking....
	      last if length($in{buf});   	# did not consume, strange.
	      last if length $stat;		# something wrong, or file ends.
	      last unless read $IN, $in{buf}, 10*1024, length($in{buf});		# try to get more data
	    }
	  my $slurped = tell $IN;	# likely to get ca. 800k yacc!
	  close $IN;
          # use Data::Dumper; warn Dumper $stat, length($in{buf}), length($uncomp_buf), "slurped=$slurped";
	}
    }

  ## try to get at the second level mime type, for some well known linear compressors.
  while (length $uncomp_buf && $r[0] =~ m{^application/(x-)?([+\w]+)$})
    {
      my $compname = $2;
      my $next_uncomp_buf = '';

      # use Data::Dumper; printf STDERR "calling mime with buf=%d bytes, compname=$compname\n", length($uncomp_buf);

      my $m2 = $self->mime(buf => $uncomp_buf, file => "$in{file}+$compname", uncomp => \$next_uncomp_buf, recursion => 1);
      my ($a,$xminus,$b) = ($m2->[0] =~ m{^(.*)/(x-)?(.*)$});
      if ($a eq 'application')
        {
	  $r[0] = "application/x-$b+$compname"
	}
      else
        {
	  $r[0] = "application/x-$a-$b+$compname"
	}
      $r[2] .= "\n" . $m2->[2];
      $uncomp_buf = $next_uncomp_buf;
      # print Dumper "new: ", \@r, $m2, $compname, length($uncomp_buf);
    }

# use Data::Dumper;
# die Dumper \@r, "--------------------";

  if ($r[0] eq 'application/unknown+zip' and $r[2] =~ m{\btext\b}i)
    {
      # empty.odt
      # ['application/unknown+zip; charset=binary','Zip archive data, at least v2.0 to extract, mime type application/vnd OpenDocument Text']
      # application/vnd.oasis.opendocument.text
      if ($mime2 ||= eval { open my $fd,'<',\$in{buf}; File::MimeInfo::Magic::magic($fd); })
        {
          $mime2 .= '+zip' unless $mime2 =~ m{\+zip}i;
          $r[0] = $mime2 if $mime2 =~ m{^application/};
	}
    }
  $r[0] .= '+zip' if $r[0] =~ m{^application/vnd\.oasis\.opendocument\.text$};

  if ($r[0] eq 'text/plain' and $in{file} =~ m{\.(mm|b64|base64)$}i)
    {
      my $suf = lc $1;
      $r[0] = "text/x-suffix-$suf+plain";
    }

  if ($r[0] eq 'application/octet-stream' and $in{file} =~ m{\.(lzma|zx|lz)$}i)
    {
      my $suf = lc $1;
      $r[0] = "application/x-suffix-$suf+octet-stream";
    }

  if ($r[0] =~ m{^application/x-(ms-dos-|)executable$})
    {
      if (-x '/usr/bin/upx')
        {
	  $r[0] .= '+upx' unless run(['/usr/bin/upx', '-q', '-q', '-t', $in{file}]);
	}
    }

  ${$in{uncomp}} = $uncomp_buf if ref $in{uncomp} eq 'SCALAR';
  $r[3] = [ $mime1, $mime2 ] if $mime1 ne $r[0] or ($mime2 and $mime2 ne $mime1);

  return \@r;
}

=head1 AUTHOR

Juergen Weigert, C<< <jnw at cpan.org> >>

=head1 BUGS

The implementation of C<mime> is an ugly hack. We suffer from the existance of
multiple file magic databases, and multiple conflicting implementations. With
perl we have at least 5 modules for this; here we use two.

The builtin list of mime-handlers is incomplete. Please submit your handler code.

Please report any bugs or feature requests to C<bug-file-unpack at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=File-Unpack>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.


=head1 RELATED MODULES

While designing File::Unpack, a range of other perl modules were examined. Many modules provide valuable service to File::Unpack and became dependencies or are recommended.
Others exposed drawbacks during closer examination and may find some of their
wheels re-invented here.

=head2 Used Modules

=over

=item File::LibMagic

This is the prefered mimetype engine. It disregards the suffix, recognizes more
types than any of the alternatives, and uses exactly the same engine as
/usr/bin/file in openSUSE systems. It also returns charset and description
information.  We crossreference the description with the mimetype to detect
weaknesses, and consult File::MimeInfo::Magic and some own logic, for e.g.
detecting LZMA compression which fails to provide any recognizable magic.
Required if you use C<mime>; otherwise not a hard requirement.

=item File::MimeInfo::Magic

Uses both magic information and file suffixes to determine the mimetype. Its
magic() function is used in a few cases, where File::LibMagic fails.  E.g. as
of June 2010, libmagic does not recognize 'image/x-targa'.
File::MimeInfo::Magic may be slower, but it features the shared-mime-info
database from freedesktop.org .  Recommended if you use C<mime>.

=item String::ShellQuote 

Used to call external mime-handlers. Required.

=item BSD::Resource

Used to reliably restrict the maximum file size. Recommended.

=item File::Path

mkpath(). Required.

=item Cwd

fast_abs_path(). Required.

=item JSON

Used for formatting the logfile. Required.

=back

=head2 Modules Not Used

=over

=item Archive::Extract

Archive::Extract tries first to determine what type of archive you are passing
it, by inspecting its suffix. 'Maybe this module should use something like
"File::Type" to determine the type, rather than blindly trust the suffix'.
[quoted from perldoc]

Set $Archive::Extract::PREFER_BIN to 1, which will prefer the use of command 
line programs and won't consume so much memory. Default: use "Archive::Tar".

=item Archive::Zip

If you are just going to be extracting zips (and/or other archives) you are 
recommended to look at using Archive::Extract . [quoted from perldoc]
It is pure perl, so it's a lot slower then your '/usr/bin/zip'.

=item Archive::Tar

It is pure perl, so it's a lot slower then your "/bin/tar".
It is heavy on memory, all will be read into memory. [quoted from perldoc]

=item File::MMagic, File::MMagic::XS, File::Type

Compared to File::LibMagic and File::MimeInfo::Magic, these three are inferior.
They often say 'text/plain' or 'application/octet-stream' where the latter two report 
useful mimetypes.

=back

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc File::Unpack


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=File-Unpack>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/File-Unpack>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/File-Unpack>

=item * Search CPAN

L<http://search.cpan.org/dist/File-Unpack/>

=back

=head1 SOURCE REPOSITORY

L<https://developer.berlios.de/projects/perl-file-unpck>

svn co L<https://svn.berlios.de/svnroot/repos/perl-file-unpck/trunk/File-Unpack>


=head1 ACKNOWLEDGEMENTS

Mime-type recognition relies heavily on libmagic by Christos Zoulas. I had long 
hesitated implementing File::Unpack, but set to work, when I dicovered
that File::LibMagic brings your library to perl. Thanks Christos. And thanks
for tcsh too.

=head1 LICENSE AND COPYRIGHT

Copyright 2010,2011 Juergen Weigert.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1; # End of File::Unpack
