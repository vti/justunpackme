package Unpacker::Archive;

use strict;
use warnings;

use Unpacker::Exception;
use Unpacker::Archive::Directory;

use Try::Tiny;
use File::Unpack ();

sub new {
    my $class = shift;

    my $self = {@_};
    bless $self, $class;

    die 'path is required' unless defined $self->{path};

    return $self;
}

sub unpack {
    my $self = shift;

    $self->directory->create;

    my $log;
    my $u = File::Unpack->new(destdir => $self->directory->path, logfile => \$log);

    my $mime = $u->mime($self->{path});

    try {
        if (!$u->find_mime_handler($mime->[0])) {
            Unpacker::Exception->throw('Unknown file format');
        }

        my $e = $u->unpack($self->{path});

        if ($e) {
            Unpacker::Exception->throw('Unpacking failed');
        }
    }
    catch {
        my $e = $_;

        $self->directory->remove;

        die $e;
    };

    return $self;
}

sub directory {
    my $self = shift;

    $self->{directory} ||= Unpacker::Archive::Directory->new(root => $self->{root});

    return $self->{directory};
}

sub rel_path { shift->directory->rel_path }

1;
