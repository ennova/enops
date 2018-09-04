package delay;

use warnings;
use strict;

use nginx;
use IO::Socket::INET;

sub handler {
  my $r = shift;

  my $start_time = $r->variable('start_time');
  unless ($start_time) {
    $start_time = time;
    $r->variable('start_time', $start_time);
  }

  my $duration = time - $start_time;

  if ($duration > 30) {
    return HTTP_BAD_GATEWAY;
  }

  if (open(my $fh, '/etc/nginx/conf.d/elasticbeanstalk-nginx-docker-upstream.conf')) {
    local $/ = undef;
    my $data = <$fh>;
    close $fh;

    if ($data =~ /server (.+):(\d+)/) {
      my $sock = IO::Socket::INET->new(
        PeerAddr => $1,
        PeerPort => $2,
        Proto => 'tcp',
        Timeout => 0.25,
      );

      if ($sock) {
        close $sock;

        $r->sleep(2000, \&done);
        return OK;
      }
    }
  }

  $r->sleep(2000, \&handler);
  return OK;
}

sub done {
  my $r = shift;
  return HTTP_BAD_GATEWAY;
}

1;
__END__
