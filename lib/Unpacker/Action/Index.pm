package Unpacker::Action::Index;

use strict;
use warnings;

use base 'Unpacker::Action';

sub run {
    my $self = shift;

    my $comments = $self->req->param('comments');
    $self->set_var(comments => defined $comments ? 1 : 0);
}

1;
