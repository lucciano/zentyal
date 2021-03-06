# Copyright (C) 2008-2013 Zentyal S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

# package:  EBox::Types::IPNetwork
#
#    Type class intended to represent addresses of IP networks
use strict;
use warnings;

package EBox::Types::IPNetwork;

use EBox::Validate qw(:all);
use EBox::Gettext;
use EBox::Exceptions::MissingArgument;

use base 'EBox::Types::IPAddr';

sub new
{
    my $class = shift;
    my %opts = @_;

    unless (exists $opts{'HTMLSetter'}) {
        $opts{'HTMLSetter'} = '/ajax/setter/ipnetworkSetter.mas';
    }

    my $self = $class->SUPER::new(%opts);

    $self->{'type'} = 'ipnetwork';

    bless($self, $class);

    return $self;
}

# Method: _paramIsValid
#
# Overrides:
#
#      <EBox::Types::Abstract::_paramIsValid>
#
sub _paramIsValid
{
    my ($self, $params) = @_;

    my $ipParam   = $self->fieldName() . '_ip';
    my $maskParam = $self->fieldName() . '_mask';

    my $ip =    $params->{$ipParam};
    my $mask =  $params->{$maskParam};

    my $printableName =  __($self->printableName());

    checkCIDR($ip . "/$mask",  $printableName);

    my ($unused, $expandedMask) = EBox::NetWrappers::to_network_without_mask("$ip/$mask");
    checkIPIsNetwork($ip, $expandedMask, $printableName, $printableName);

    return 1;
}

# Function : checkIPIsNetwork
#
#       Checks if the IP and the mask are valid and that the IP is  a
#       network  with the given mask.
#
#       Note that both name_ip and name_mask should be set, or not set at all
#
#
# Parameters:
#
#       ip - IPv4 address
#       mask -  network mask address
#       name_ip - Data's name to be used when throwing an Exception
#       name_mask - Data's name to be used when throwing an Exception
#
# Returns:
#
#       boolean - True if it is a valid IPv4 address and network, false otherwise
#
# Exceptions:
#
#       If name is passed an exception could be raised
#
#       InvalidData - ip/mask is incorrect
#   check that a given IP and netmask correspond to a IP networ
#
#
#  Warning:
#
#  derived from EBox::Validate::checkIPNetmask
#  XXX move to eBox::VAlidate if needed
sub checkIPIsNetwork
{
    my ($ip,$mask,$name_ip, $name_mask) = @_;

    checkIP($ip,$name_ip);
    checkNetmask($mask,$name_mask);

    my $ip_bpack = pack("CCCC", split(/\./, $ip));
    my $mask_bpack = pack("CCCC", split(/\./, $mask));

    my $net_bits = unpack("B*", $ip_bpack & (~$mask_bpack));

    my $isNetwork = ($net_bits =~ /^0+$/);
    if (not $isNetwork) {
        if ($name_ip) {
            throw EBox::Exceptions::InvalidData
                ('data' => $name_ip . "/" . $name_mask,
                 'value' => $ip . "/" . $mask);
        } else {
            return undef;
        }
    }

    return 1;
}

1;
