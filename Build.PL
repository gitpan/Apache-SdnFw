use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new(
	module_name => 'Apache::SdnFw',
	license => 'perl',
	requires => {
		perl => '5.6.1',
		'DBI' => 0,
		'DBD::Pg' => 0,
		'Template' => 0,
		'Time::Ctime' => 0,
		'LWP::UserAgent' => 0,
		'Crypt::CBC' => 0,
		'Crypt::Blowfish' => 0,
		'XML::Dumper' => 0,
		'XML::Simple' => 0,
		'Net::SMTP::SSL' => 0,
		'Net::FTP' => 0,
		'Digest::MD5' => 0,
		'MIME::Base64' => 0,
		'MIME::QuotedPrint' => 0,
		'Date::Format' => 0,
		'Data::Dumper' => 0,
		'Lingua::EN::Numbers' => 0,
		'Google::SAML::Response' => 0,
		},
	);

$build->create_build_script;
