package Apache::SdnFw;

use strict;
use Carp;
use Apache;
use Apache::Constants qw(:common :response :http);
use Compress::Zlib 1.0;
use Time::HiRes qw(time);
use Date::Format;
use Apache::SdnFw::lib::Core;

our $VERSION = '0.90';

sub handler {
	my $r = shift;

	# our goal here is to facilitate handing off to the main
	# system processor with some basic information
	# which will then return a very structured data object
	# back, which we will then dump back out to the client

	my %options;
	$options{uri} = $r->uri();
	$options{args} = $r->args();
	$options{remote_addr} = $r->get_remote_host();

	my %headers = $r->headers_in();
	if ($headers{Cookie}) {
		foreach my $kv (split '; ', $headers{Cookie}) {
			my ($k,$v) = split '=', $kv;
			$options{cookies}{$k} = $v;
		}
	}
	$options{server_name} = $headers{Host};
	$options{server_name} =~ s/^www\.//;

	# pull in some other information
	foreach my $key (qw(
		HTTPS HTTPD_ROOT HTTP_COOKIE HTTP_REFERER HTTP_USER_AGENT DB_STRING
		DB_USER BASE_URL DOCUMENT_ROOT REQUEST_METHOD QUERY_STRING HIDE_PERMISSION
		GOOGLE_MAPS_KEY DEV FORCE_HTTPS GAUTH GUSER IP_LOGIN TITLE IPHONE DBDEBUG
		OBJECT_BASE CONTENT_LENGTH CONTENT_TYPE APACHE_SERVER_NAME IP_ADDR)) {

		$options{env}{$key} = ($r->dir_config($key) or $r->subprocess_env->{$key});
	}

	# get incoming parameters (black box function)
	get_params($r,\%options);

	# kill some shit
	foreach my $k (qw(__EVENTARGUMENT __EVENTVALIDATION __VIEWSTATE __EVENTTARGET)) {
		delete $options{in}{$k};
	}

	# what content type do we want back? (default to text/html)
	$options{content_type} = $options{in}{c} || 'text/html';

	# try and get a Core object and pass this information to it
	# setup our database debug output file
	if ($options{env}{DBDEBUG}) {
		_start_dbdebug(\%options);
	}

	my $s;
	eval {
		$s = Apache::SdnFw::lib::Core->new(%options);
		$s->process();
		#croak "test".Data::Dumper->Dump([$s]);
	};

	if ($options{env}{DBDEBUG}) {
		_end_dbdebug($s);
	}

	# so from all that happens below here is what $s->{r} should have
	# error => ,
	# redirect => ,
	# return_code => ,
	# set_cookie => [ array ],
	# filename => ,
	# file_path => ,
	# content => ,

	if ($@) {
		$s->{dbh}->rollback if (defined($s->{dbh}));;
		return error($r,"Eval Error: $@");
	}

	unless(ref $s->{r} eq "HASH") {
		return error($r,"r hash not returned by core");
	}

	if ($s->{r}{error}) {
		return error($r,"Process Error: $s->{r}{error}");
	}

	if ($s->{r}{redirect}) {
		$r->header_out('Location' => $s->{r}{redirect});
		return MOVED;
	}

	#if ($s->{r}{remote_user}) {
	#	$r->subprocess_env(REMOTE_USER => $s->{r}{remote_user});
		$r->subprocess_env(USER_ID => $s->{r}{log_user});
		$r->subprocess_env(LOCATION_ID => $s->{r}{log_location});
	#}

	if ($s->{r}{return_code}) {
		return NOT_FOUND if ($s->{r}{return_code} eq "NOT_FOUND");
		return FORBIDDEN if ($s->{r}{return_code} eq "FORBIDDEN");

		# unknown return code
		return error($r,"Unknown return_code: $s->{r}{return_code}");
	}

	# add cookies
	foreach my $cookie (@{$s->{r}{set_cookie}}) {
		$r->err_headers_out->add('Set-Cookie' => $cookie);
	}

	#return error($r,"Missing content_type") unless($s->{r}{content_type});

	# compress the data?
	my $gzip = $r->header_in('Accept-Encoding') =~ /gzip/;
	if ($gzip && !$s->{r}{file_path}) {
		if ($r->protocol =~ /1\.1/) {
			my %vary = map {$_,1} qw(Accept-Encoding User-Agent);
			if (my @vary = $r->header_out('Vary')) {
				@vary{@vary} = ();
			}
			$r->header_out('Vary' => join ',', keys %vary);
		}
		$r->content_encoding('gzip');
	}

	$r->content_type($s->{r}{content_type});
	$r->headers_out->add('Content-Disposition' => "filename=$s->{r}{filename}")
		if ($s->{r}{filename});
	$r->send_http_header;

	if ($s->{r}{file_path}) {
		# send a raw file
		open(FILE, $s->{r}{file_path});
		$r->send_fd( \*FILE );
		close(FILE);
	} else {
		# or just send back content

		wrap_template($s) if ($s->{r}{content_type} eq 'text/html' && !$s->{raw_html});

		if ($s->{save_static}) {
			my $fname = "$s->{object}_$s->{function}.html";
			open F, ">/data/$s->{obase}/content/$fname";
			print F $s->{r}{content};
			close F;
		}

		if ($gzip) {
			$r->print(Compress::Zlib::memGzip($s->{r}{content}));
		} else {
			$r->print($s->{r}{content});
		
		}
	}

	return HTTP_OK;
}

sub wrap_template {
	my $s = shift;

#		'<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">'.
	$s->{r}{content} = <<END;
<!DOCTYPE html>
<html lang="en">
<head>
	<meta charset="utf-8" />
	<link rel="shortcut icon" href="/favicon.ico">
$s->{r}{head}
</head>
<body $s->{r}{body}>
$s->{r}{content}
</body>
</html>
END

}

sub _start_dbdebug {
	my $options = shift;

	$options->{dbdbst} = time;
	$options->{dbdbdata} = "!!!$options->{dbdbst}|$options->{uri}\t";
}

sub _end_dbdebug {
	my $s = shift;

	my $elapse = sprintf "%.4f", time-$s->{dbdbst};

	$s->{dbdbdata} .= "###($elapse)";

	my $sock = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1',
		PeerPort => 11271,
		Proto => 'udp',
		Blocking => 0,
		);
	
	print $sock $s->{dbdbdata};
	$sock->close();
}

sub error {
	my $r = shift;
	my $msg = shift;

	# TODO: Dump out the message somewhere
	# about where this error occured

	# for now just print the crap that comes back
	#$r->content_type('text/plain');
	#$r->send_http_header;
	$r->print($msg);

	return HTTP_OK;
}

sub get_params {
	my $r = shift;
	my $o = shift;

	my $input;
	if ($o->{env}{REQUEST_METHOD} ne "GET") {
		my $buffer;         
		while (my $ret = $r->read_client_block($buffer,2048)) {
			$input .= substr($buffer,0,$ret);
		}
		$o->{raw_input} = $input;
		if ($o->{env}{CONTENT_TYPE} =~ /^multipart\/form-data/) {
			my (@pairs,$boundary,$part);
			($boundary = $o->{env}{CONTENT_TYPE}) =~ s/^.*boundary=(.*)$/$1/;
			@pairs = split(/--$boundary/, $input);
			@pairs = splice(@pairs,1,$#pairs-1);
			for $part (@pairs) {
				$part =~ s/[\r]\n$//g;
				my ($blankline,$name,$currentColumn);
				my ($dump, $firstline, $datas) = split(/[\r]\n/, $part, 3);
				next if $firstline =~ /filename=\"\"/;
				# ignore stuff that starts with _raw:
				next if ($datas =~ m/^_raw:/i);
				$firstline =~ s/^Content-Disposition: form-data; //;
				my (@columns) = split(/;\s+/, $firstline);
				($name = $columns[0]) =~ s/^name="([^"]+)"$/$1/g;
				if ($#columns > 0) {
					if ($datas =~ /^Content-Type:/) {
						($o->{in}{$name}{'Content-Type'}, $blankline, $datas) = split(/[\r]\n/, $datas, 3);
						$o->{in}{$name}{'Content-Type'} =~ s/^Content-Type: ([^\s]+)$/$1/g;
					} else {
						($blankline, $datas) = split(/[\r]\n/, $datas, 2);
						$o->{in}{$name}{'Content-Type'} = "application/octet-stream";
					}
				} else {
					($blankline, $datas) = split(/[\r]\n/, $datas, 2);
					if (grep(/^$name$/, keys(%{$o->{in}}))) {
						if (exists($o->{in}{$name}) && (ref($$o{in}{$name}) eq 'ARRAY')) {
							push(@{$o->{in}{$name}}, $datas);
						} else {
							my $arrvalue = $o->{in}{$name};
							undef $o->{in}{$name};
							$o->{in}{$name}[0] = $arrvalue;
							push(@{$o->{in}{$name}}, $datas);
						}
					} else {
						$o->{in}{$name} = "", next if $datas =~ /^\s*$/;
						$o->{in}{$name} = $datas;
					}
					next;
				}
				for $currentColumn (@columns) {
					my ($currentHeader, $currentValue) = $currentColumn =~ /^([^=]+)="([^"]+)"$/;
					$o->{in}{$name}{$currentHeader} = $currentValue;
				}
				$o->{in}{$name}{'Contents'} = $datas;
			}
			undef $input;
		}
	}

	if ($o->{env}{QUERY_STRING}) {
		$input .= "&" if ($input);
		$input .= $o->{env}{QUERY_STRING};
	}

	my @kv = split('&',$input);
	foreach (@kv) {
		my ($k,$v) = split('=');
		$k =~ s/\+/ /g;
		$k =~ s/%([\dA-Fa-f][\dA-Fa-f])/pack ("C", hex ($1))/eg;
		$v =~ s/\+/ /g;
		$v =~ s/%([\dA-Fa-f][\dA-Fa-f])/pack ("C", hex ($1))/eg;
		# ignore stuff that starts with _raw:
		next if ($v =~ m/^_raw:/i);

		if (defined $o->{in}{$k}) {
			$o->{in}{$k} .= ",$v";
		} else {
			$o->{in}{$k} = $v;
		}
	}

	foreach my $k (keys %{$o->{in}}) {
		if ($k =~ m/^[\dA-Fa-f]{32}::(.+)$/) {
			# check and see if we need to kill any acfb value (autocomplete form busting)
			$o->{in}{$1} = delete $o->{in}{$k};
		}
	}
}

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

Apache::SdnFw - Perl extension for blah blah blah

=head1 SYNOPSIS

  use Apache::SdnFw;
  blah blah blah

=head1 DESCRIPTION

Stub documentation for Apache::SdnFw, created by h2xs. It looks like the
author of the extension was negligent enough to leave the stub
unedited.

Blah blah blah.

=head2 EXPORT

None by default.



=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

Chris Sutton, E<lt>chris@smalldognet.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by Chris Sutton

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.


=cut
