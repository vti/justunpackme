package Unpacker::Action::Archive;

use strict;
use warnings;

use base 'Unpacker::Action';

use Unpacker::Archive;
use Lamework::Registry;

sub new {
    my $self = shift->SUPER::new(@_);

    $self->set_template('index');

    return $self;
}

sub _unpack_archive {
    my $self = shift;
    my ($path) = @_;

    my $home    = Lamework::Registry->get('home');
    my $archive = Unpacker::Archive->new(
        root => $home->catfile('htdocs', 'uploads'),
        path => $path
    );

    $archive->unpack;

    return $archive;
}

1;
