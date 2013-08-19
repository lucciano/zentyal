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
use strict;
use warnings;

# Class: EBox::Samba::Model::SambaShares
#
#  This model is used to configure shares different to those which are
#  given by the group share
#
package EBox::Samba::Model::SambaShares;

use base 'EBox::Model::DataTable';

use Cwd 'abs_path';
use String::ShellQuote;

use EBox::Gettext;
use EBox::Global;
use EBox::Types::Text;
use EBox::Types::Union;
use EBox::Types::Boolean;
use EBox::Model::Manager;
use EBox::Exceptions::DataInUse;
use EBox::Samba::SecurityPrincipal;
use EBox::Sudo;

use EBox::Samba::Security::SecurityDescriptor;
use EBox::Samba::Security::AccessControlEntry;

use Error qw(:try);

use constant DEFAULT_MASK => '0700';
use constant DEFAULT_USER => 'root';
use constant DEFAULT_GROUP => 'root';
use constant GUEST_DEFAULT_MASK => '0770';
use constant GUEST_DEFAULT_USER => 'nobody';
use constant GUEST_DEFAULT_GROUP => 'nogroup';
use constant FILTER_PATH => ('/bin', '/boot', '/dev', '/etc', '/lib', '/root',
                             '/proc', '/run', '/sbin', '/sys', '/var', '/usr');

# Constructor: new
#
#     Create the new Samba shares table
#
# Overrides:
#
#     <EBox::Model::DataTable::new>
#
# Returns:
#
#     <EBox::Samba::Model::SambaShares> - the newly created object
#     instance
#
sub new
{
    my ($class, %opts) = @_;

    my $self = $class->SUPER::new(%opts);
    bless ($self, $class);

    return $self;
}

# Method: updatedRowNotify
#
#      Notify cloud-prof if installed to be restarted
#
# Overrides:
#
#      <EBox::Model::DataTable::updatedRowNotify>
#
sub updatedRowNotify
{
    my ($self, $row, $oldRow, $force) = @_;
    if ($row->isEqualTo($oldRow)) {
        # no need to notify changes
        return;
    }

    my $global = EBox::Global->getInstance();
    if ( $global->modExists('cloud-prof') ) {
        $global->modChange('cloud-prof');
    }
}

# Method: _table
#
# Overrides:
#
#     <EBox::Model::DataTable::_table>
#
sub _table
{
    my ($self) = @_;

    my @tableDesc = (
       new EBox::Types::Boolean(
                               fieldName     => 'sync',
                               printableName => __('Sync with Zentyal Cloud'),
                               editable      => 1,
                               defaultValue  => 0,
                               help          => __('Files will be synchronized with Zentyal Cloud.'),
                               hidden        => \&_hideSyncOption,
                               ),
       new EBox::Types::Text(
                               fieldName     => 'share',
                               printableName => __('Share name'),
                               editable      => 1,
                               unique        => 1,
                              ),
       new EBox::Types::Union(
                               fieldName => 'path',
                               printableName => __('Share path'),
                               subtypes =>
                                [
                                     new EBox::Types::Text(
                                       fieldName     => 'zentyal',
                                       printableName =>
                                            __('Directory under Zentyal'),
                                       editable      => 1,
                                       unique        => 1,
                                                        ),
                                     new EBox::Types::Text(
                                       fieldName     => 'system',
                                       printableName => __('File system path'),
                                       editable      => 1,
                                       unique        => 1,
                                                          ),
                               ],
                               help => _pathHelp($self->parentModule()->SHARES_DIR())),
       new EBox::Types::Text(
                               fieldName     => 'comment',
                               printableName => __('Comment'),
                               editable      => 1,
                              ),
       new EBox::Types::Boolean(
                                   fieldName     => 'guest',
                                   printableName => __('Guest access'),
                                   editable      => 1,
                                   defaultValue  => 0,
                                   help          => __('This share will not require authentication.'),
                                   ),
       new EBox::Types::HasMany(
                               fieldName     => 'access',
                               printableName => __('Access control'),
                               foreignModel => 'SambaSharePermissions',
                               view => '/Samba/View/SambaSharePermissions'
                              ),
       # This hidden field is filled with the group name when the share is configured as
       # a group share through the group addon
       new EBox::Types::Text(
            fieldName => 'groupShare',
            hidden => 1,
            optional => 1,
            ),
      );

    my $dataTable = {
                     tableName          => 'SambaShares',
                     printableTableName => __('Shares'),
                     modelDomain        => 'Samba',
                     defaultActions     => [ 'add', 'del',
                                             'editField', 'changeView' ],
                     tableDescription   => \@tableDesc,
                     menuNamespace      => 'Samba/View/SambaShares',
                     class              => 'dataTable',
                     help               => _sharesHelp(),
                     printableRowName   => __('share'),
                     enableProperty     => 1,
                     defaultEnabledValue => 1,
                     orderedBy          => 'share',
                    };

      return $dataTable;
}

# Method: validateTypedRow
#
#       Override <EBox::Model::DataTable::validateTypedRow> method
#
#   Check if the share path is allowed or not
sub validateTypedRow
{
    my ($self, $action, $parms)  = @_;

    return unless ($action eq 'add' or $action eq 'update');

    if (exists $parms->{'path'}) {
        my $path = $parms->{'path'}->selectedType();
        if ($path eq 'system') {
            # Check if it is an allowed system path
            my $normalized = abs_path($parms->{'path'}->value());
            if ($normalized eq '/') {
                throw EBox::Exceptions::External(__('The file system root directory cannot be used as share'));
            }
            foreach my $filterPath (FILTER_PATH) {
                if ($normalized =~ /^$filterPath/) {
                    throw EBox::Exceptions::External(
                            __x('Path not allowed. It cannot be under {dir}',
                                dir => $normalized
                               )
                    );
                }
            }
            EBox::Validate::checkAbsoluteFilePath($parms->{'path'}->value(),
                                           __('Samba share absolute path')
                                                );
        } else {
            # Check if it is a valid directory
            my $dir = $parms->{'path'}->value();
            EBox::Validate::checkFilePath($dir,
                                         __('Samba share directory'));
        }
    }
}

# Method: removeRow
#
#   Override <EBox::Model::DataTable::removeRow> method
#
#   Overriden to warn the user if the directory is not empty
#
sub removeRow
{
    my ($self, $id, $force) = @_;

    my $row = $self->row($id);

    if ($force or $row->elementByName('path')->selectedType() eq 'system') {
        return $self->SUPER::removeRow($id, $force);
    }

    my $path =  $self->parentModule()->SHARES_DIR() . '/' .
                $row->valueByName('path');
    unless ( -d $path) {
        return $self->SUPER::removeRow($id, $force);
    }

    opendir (my $dir, $path);
    while(my $entry = readdir ($dir)) {
        next if($entry =~ /^\.\.?$/);
        closedir ($dir);
        throw EBox::Exceptions::DataInUse(
         __('The directory is not empty. Are you sure you want to remove it?'));
    }
    closedir($dir);

    return $self->SUPER::removeRow($id, $force);
}

# Method: deletedRowNotify
#
#   Override <EBox::Model::DataTable::validateRow> method
#
#   Write down shares directories to be removed when saving changes
#
sub deletedRowNotify
{
    my ($self, $row) = @_;

    my $path = $row->elementByName('path');

    # We are only interested in shares created under /home/samba/shares
    return unless ($path->selectedType() eq 'zentyal');

    my $mgr = EBox::Model::Manager->instance();
    my $deletedModel = $mgr->model('SambaDeletedShares');
    $deletedModel->addRow('path' => $path->value());
}

# Method: createDirs
#
#   This method is used to create the necessary directories for those
#   shares which must live under /home/samba/shares
#   We must set here both POSIX ACLs and navite NT ACLs. If we only set
#   POSIX ACLs, a user can change the permissions in the security tab
#   of the share. To avoid it we set also navive NT ACLs and set the
#   owner of the share to 'Domain Admins'.
#
sub createDirs
{
    my ($self, $recursive) = @_;

    for my $id (@{$self->ids()}) {
        my $row = $self->row($id);
        my $shareName   = $row->valueByName('share');
        my $pathType    = $row->elementByName('path');
        my $guestAccess = $row->valueByName('guest');

        my $path = undef;
        if ($pathType->selectedType() eq 'zentyal') {
            $path = $self->parentModule()->SHARES_DIR() . '/' . $pathType->value();
        } elsif ($pathType->selectedType() eq 'system') {
            $path = $pathType->value();
        } else {
            EBox::error("Unknown share type on share '$shareName'");
        }
        next unless defined $path;

        # Don't do anything if the directory already exists and the option to manage ACLs
        # only from Windows is set
        next if (EBox::Config::boolean('unmanaged_acls') and EBox::Sudo::fileTest('-d', $path));

        my @cmds = ();
        push (@cmds, "mkdir -p '$path'");
        if ($guestAccess) {
           push (@cmds, 'chmod ' . GUEST_DEFAULT_MASK . " '$path'");
           push (@cmds, 'chown ' . GUEST_DEFAULT_USER . ':' . GUEST_DEFAULT_GROUP . " '$path'");
        } else {
           push (@cmds, 'chmod ' . DEFAULT_MASK . " '$path'");
           push (@cmds, 'chown ' . DEFAULT_USER . ':' . DEFAULT_GROUP . " '$path'");
        }
        EBox::Sudo::root(@cmds);

        my $sd = undef;
        if ($guestAccess) {
            my $sd = new EBox::Samba::Security::SecurityDescriptor(ownerSID => 'WD', groupSID => 'WD');
            my $ace = new EBox::Samba::Security::AccessControlEntry(type => 'A', flags => ('OI', 'CI'), rights => ('FR', 'FW', 'FX'), objectSID => 'WD');
            $sd->addDACL($ace);
            my $sdString = $sd->getAsString();
            my $cmd = EBox::Samba::SAMBATOOL() . " ntacl set '$sdString' '$path'";
            try {
                EBox::Sudo::root($cmd);
            } otherwise {
                my ($error) = @_;
                EBox::error("Could not set NT ACL for $path: $error");
            };
            next;
        }

        my $sd = new EBox::Samba::Security::SecurityDescriptor(ownerSID => 'BA', groupSID => 'DU');
        $sd->addDACL(new EBox::Samba::Security::AccessControlEntry(type => 'A', flags => ['OI', 'CI'], rights => ['FA'], objectSID => 'SY'));
        $sd->addDACL(new EBox::Samba::Security::AccessControlEntry(type => 'A', flags => ['OI', 'CI'], rights => ['FA'], objectSID => 'BA'));
        $sd->addDACL(new EBox::Samba::Security::AccessControlEntry(type => 'A', flags => ['OI', 'CI'], rights => ['FA'], objectSID => 'LA'));

        for my $subId (@{$row->subModel('access')->ids()}) {
            my $subRow = $row->subModel('access')->row($subId);
            my $permissions = $subRow->elementByName('permissions');

            my $userType = $subRow->elementByName('user_group');
            my $account = $userType->printableValue();
            my $qobject = shell_quote($account);

            my $object = new EBox::Samba::LdbObject(samAccountName => $account);
            next unless $object->exists();

            my $sid = $object->sid();
            if ($permissions->value() eq 'readOnly') {
                $sd->addDACL(new EBox::Samba::Security::AccessControlEntry(type => 'A', flags => ['OI', 'CI'], rights => ['FR', 'FX'], objectSID => $sid));
            } elsif ($permissions->value() eq 'readWrite') {
                $sd->addDACL(new EBox::Samba::Security::AccessControlEntry(type => 'A', flags => ['OI', 'CI'], rights => ['FR', 'FX', 'FW', 'SD'], objectSID => $sid));
            } elsif ($permissions->value() eq 'administrator') {
                $sd->addDACL(new EBox::Samba::Security::AccessControlEntry(type => 'A', flags => ['OI', 'CI'], rights => ['FA'], objectSID => $sid));
            } else {
                my $type = $permissions->value();
                EBox::error("Unknown share permission type '$type'");
                next;
            }
        }

        # Setting NT ACLs also sets posix ACLs thanks to vfs_xattr plugin
        try {
            my $sdString = $sd->getAsString();
            if ($recursive) {
                EBox::info("Setting NT ACLs recursively on share '$path', this can take a while");
                my $cmd = EBox::Samba::SAMBATOOL() . " ntacl set --recursive '$sdString' '$path'";
                EBox::Sudo::root($cmd);
            } else {
                my $cmd = EBox::Samba::SAMBATOOL() . " ntacl set '$sdString' '$path'";
                EBox::Sudo::root($cmd);
            }
        } otherwise {
            my $error = shift;
            EBox::error("Coundn't enable NT ACLs for $path: $error");
        };
    }
}

# Private methods

sub _hideSyncOption
{
    if (EBox::Global->modExists('remoteservices')) {
        my $rs = EBox::Global->modInstance('remoteservices');
        return (not $rs->filesSyncAvailable() or _syncAllShares());
    }

    return 1;
}

sub _syncAllShares
{
    my $samba = EBox::Global->modInstance('samba');
    return $samba->model('SyncShares')->syncValue();
}

sub _pathHelp
{
    my ($sharesPath) = @_;

    return __x( '{openit}Directory under Zentyal{closeit} will ' .
            'automatically create the share.' .
            "directory in {sharesPath} {br}" .
            '{openit}File system path{closeit} will allow you to share '.
            'an existing directory within your file system',
               sharesPath => $sharesPath,
               openit  => '<i>',
               closeit => '</i>',
               br      => '<br>');

}

sub _sharesHelp
{
    return __('Here you can create shares with more fine-grained permission ' .
              'control. ' .
              'You can use an existing directory or pick a name and let Zentyal ' .
              'create it for you.');
}

# Method: headTile
#
#   Overrides <EBox::Model::DataTable::headTitle>
#
#
sub headTitle
{
    return undef;
}

1;
