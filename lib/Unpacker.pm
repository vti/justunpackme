package Unpacker;

use strict;
use warnings;

use base 'Lamework';

use Plack::Builder;

sub compile_psgi_app {
    my $self = shift;

    my $app = sub {
        my $env = shift;

        return [404, [], ['404 Not Found']];
    };

    builder {
        enable 'Static' => path => qr{^/static},
          root          => "htdocs";

        enable 'SimpleLogger', level => 'debug';

        enable '+Lamework::Middleware::RoutesDispatcher';

        enable '+Lamework::Middleware::ActionBuilder';

        enable '+Lamework::Middleware::ViewDisplayer';

        $app;
    };
}

sub startup {
    my $self = shift;

    my $routes = $self->routes;

    $routes->add_route(
        '/',
        name     => 'index',
        defaults => {action => 'Index'},
        method   => 'get'
    );
    $routes->add_route(
        '/upload',
        name     => 'index',
        defaults => {action => 'Upload'},
        method   => 'post'
    );
    $routes->add_route(
        '/fetch',
        name     => 'fetch',
        defaults => {action => 'Fetch'}
    );
    $routes->add_route(
        '/:path/(*tail)?',
        name     => 'view',
        defaults => {action => 'View'},
        method   => 'get'
    );

    return $self;
}

1;
