package Unpacker::Action::View;

use strict;
use warnings;

use base 'Unpacker::Action';

use Lamework::Registry;
use Unpacker::Archive;
use Unpacker::App::Directory;

sub run {
    my $self = shift;

    my $home = Lamework::Registry->get('home');
    my $app = Unpacker::App::Directory->new(
        {root => $home->catfile('htdocs/uploads')})->to_app;

    my $res = $app->($self->env);

    $self->res->code($res->[0]);
    $self->res->headers($res->[1]);
    $self->res->body($res->[2]);
}

1;
