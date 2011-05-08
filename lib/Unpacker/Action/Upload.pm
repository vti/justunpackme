package Unpacker::Action::Upload;

use strict;
use warnings;

use base 'Unpacker::Action::Archive';

use Input::Validator;
use Try::Tiny;

sub run {
    my $self = shift;

    my $validator = Input::Validator->new;
    $validator->field('archive')->required(1);

    if ($validator->validate({%{$self->req->parameters}, %{$self->req->uploads}})) {
        my $upload = $self->req->upload('archive');

        my $max_size_in_megs =
          Lamework::Registry->get('config')->{max_upload_size} || 10;

        try {
            if ($upload->size > $max_size_in_megs * 1024 * 1024) {
                Lamework::Exception->throw(
                    "File size is too big (max $max_size_in_megs Mb)");
            }

            my $archive = $self->_unpack_archive($upload->path);

            return $self->redirect('view', path => $archive->rel_path);
        }
        catch {
            my $e = $_;

            die $e unless ref $e && $e->isa('Lamework::Exception');

            $self->set_var('upload_errors' => {archive => $e->error});
        };
    }
    else {
        $self->set_var('upload_errors' => $validator->errors);
    }
}

1;
