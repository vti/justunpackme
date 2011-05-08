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

    my $body = $res->[2];
    $self->res->code($res->[0]);
    $self->res->headers([@{$res->[1]}, 'Content-Length' => length($body->[0])]);
    $self->res->body($body);
}

1;
