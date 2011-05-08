package Unpacker::Archive::Directory;

use strict;
use warnings;

sub new {
    my $class = shift;

    my $self = {@_};
    bless $self, $class;

    die "Missing 'root' argument" unless $self->{root};

    return $self;
}

sub create {
    my $self = shift;

    File::Path::make_path($self->path) or die "Can't create " . $self->path;

    return $self;
}

sub remove {
    my $self = shift;

    File::Path::remove_tree($self->path) or die "Can't remove " . $self->path;

    return $self;
}

sub path { 
    my $self = shift;

    return File::Spec->catfile($self->{root}, $self->rel_path);
}

sub rel_path { 
    my $self = shift;

    return $self->id;
}

sub id {
    my $self = shift;

    return $self->{id} if $self->{id};

    my $id;
    for (1 .. 5) {
        my $attempt = $self->_generate_id;
        if (!-e File::Spec->catfile($self->{root}, $attempt)) {
            $id = $attempt;
            last;
        }
    }

    die "Can't generate unique id" unless $id;

    return $self->{id} = $id;
}

sub _generate_id {
    my $self = shift;

    my @alpha = (0 .. 9, 'a' .. 'z', 'A' .. 'Z');

    my $id = '';
    for (1 .. 8) {
        $id .= $alpha[rand(@alpha)];
    }

    return $id;
}

1;
