#!/usr/bin/perl
# Perl twin of lib/mint-supabase-keys.mjs, for the Kong image, which ships perl but no node.
# It must produce byte-identical tokens: Kong's key-auth compares the `apikey` header as a string.
# The secret is read from the environment, never from argv.
use strict;
use warnings;
use Digest::SHA qw(hmac_sha256);
use MIME::Base64 qw(encode_base64);

my $secret = $ENV{JWT_SECRET} // '';
if (length($secret) < 32) {
    print STDERR "mint-keys: JWT_SECRET must be at least 32 characters\n";
    exit 2;
}

sub b64url {
    my $s = encode_base64($_[0], '');
    $s =~ s/=+$//;
    $s =~ tr{+/}{-_};
    return $s;
}

my $header = '{"alg":"HS256","typ":"JWT"}';
sub mint {
    my ($role) = @_;
    my $claims = '{"role":"' . $role . '","iss":"supabase","iat":1735689600,"exp":2082758400}';
    my $unsigned = b64url($header) . '.' . b64url($claims);
    return $unsigned . '.' . b64url(hmac_sha256($unsigned, $secret));
}

print 'ANON_KEY=' . mint('anon') . "\n";
print 'SERVICE_ROLE_KEY=' . mint('service_role') . "\n";
