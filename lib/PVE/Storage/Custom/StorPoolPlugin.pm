# SPDX-FileCopyrightText: StorPool <support@storpool.com>
# SPDX-License-Identifier: BSD-2-Clause

package PVE::Storage::Custom::StorPoolPlugin;

use v5.16;

use strict;
use warnings;

use Carp qw(carp croak);
use Config::IniFiles;
use Data::Dumper;
use File::Path;
use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);
use Sys::Hostname;
use Sys::Syslog qw(syslog);
use List::Util qw'first';

use JSON;
use LWP::UserAgent;
use LWP::Simple;

use version; our $VERSION = version->declare("v0.3.1");
use base qw(PVE::Storage::Plugin);

my ($RE_DISK_ID, $RE_GLOBAL_ID, $RE_PROXMOX_ID, $RE_VM_ID);
BEGIN {
    $RE_DISK_ID = '(?: 0 | [1-9[0-9]* )';
    $RE_GLOBAL_ID = '[a-z0-9]+ \. [a-z0-9+] \. [a-z0-9]+';
    $RE_PROXMOX_ID = '[a-z] [a-z0-9_.-]* [a-z0-9]';
    $RE_VM_ID = '[1-9][0-9]*';
}

# The volume tags that we look for and set
use constant {
    VTAG_VIRT => 'virt',
    VTAG_LOC => 'pve-loc',
    VTAG_STORE => 'pve',
    VTAG_TYPE => 'pve-type',
    VTAG_VM => 'pve-vm',
    VTAG_DISK => 'pve-disk',
    VTAG_BASE => 'pve-base',
    VTAG_COMMENT => 'pve-comment',
    VTAG_SNAP => 'pve-snap',
    VTAG_SNAP_PARENT => 'pve-snap-v',

    VTAG_V_PVE => 'pve',

    RE_NAME_GLOBAL_ID => qr{
        ^
        [~]
        (?P<global_id> $RE_GLOBAL_ID )
        $
    }x,

    RE_VOLNAME_ISO => qr{
        ^
        (?P<comment> .* )
        -sp- (?P<global_id> $RE_GLOBAL_ID )
        \.iso
        $
    }x,
    RE_VOLNAME_IMG => qr{
        ^
        img
        - (?P<comment> .* )
        -sp- (?P<global_id> $RE_GLOBAL_ID )
        \.raw
        $
    }x,
    RE_VOLNAME_SNAPSHOT => qr{
        ^
        snap
        - (?P<vm_id> $RE_VM_ID )
        -disk- (?P<disk_id> $RE_DISK_ID )
        - (?P<snapshot> $RE_PROXMOX_ID )
        -p- (?P<parent_id> $RE_GLOBAL_ID )
        -sp- (?P<global_id> $RE_GLOBAL_ID )
        \.raw
        $
    }x,
    RE_VOLNAME_VMSTATE => qr{
        ^
        snap
        - (?P<vm_id> $RE_VM_ID )
        -state
        - (?P<snapshot> $RE_PROXMOX_ID )
        -sp- (?P<global_id> $RE_GLOBAL_ID )
        \.raw
        $
    }x,
    RE_VOLNAME_BASE => qr{
        ^
        base
        - (?P<vm_id> $RE_VM_ID )
        -disk- (?P<disk_id> $RE_DISK_ID )
        -sp- (?P<global_id> $RE_GLOBAL_ID )
        \.raw
        $
    }x,
    RE_VOLNAME_DISK => qr{
        ^
        vm
        - (?P<vm_id> $RE_VM_ID )
        -disk- (?P<disk_id> $RE_DISK_ID )
        -sp- (?P<global_id> $RE_GLOBAL_ID )
        \.raw
        $
    }x,

    RE_VOLNAME_PROXMOX_VMSTATE => qr{
        ^
        vm
        - (?P<vm_id> $RE_VM_ID )
        -state
        - (?P<snapshot> $RE_PROXMOX_ID )
        (?: \.raw )?
        $
    }x,

	SP_PVE_Q_LOG => '/var/log/storpool/pve-storpool-query.log',
};

my $SP_VERS = '1.0';

#TODO upload same iso on two storpool templates (test)
#TODO disks list shows iso files from other templates
#TODO disks list shows saved states



sub log_and_die($) {
    my ($msg) = @_;

    syslog 'err', 'StorPool plugin: %s', $msg;
    croak "$msg\n";
}

sub log_info($) {
    my ($msg) = @_;
    syslog 'info', 'StorPool plugin: %s', $msg;
}

# Wrapper functions for the actual request
sub sp_get($$) {
	my ($cfg, $addr) = @_;

	return sp_request($cfg, 'GET', $addr, undef);
}

sub sp_post($$$) {
	
	my ($cfg, $addr, $params) = @_;
	my $res = sp_request($cfg, 'POST', $addr, $params);
	return $res
}

sub sp_request_log_response($$$$) {
	my ($cfg, $method, $addr, $response) = @_;
	my $outf;
	open($outf, '>>', SP_PVE_Q_LOG) or do {
		warn("Could not open the ".SP_PVE_Q_LOG." logfile: $!\n");
		return;
	};
	my $content = $response->decoded_content;
	chomp $content;
	say $outf gmtime()." [$$] Q $method $addr ".$response->code.' '.substr($content, 0, 1024).
		(length($content) > 1024 ? '...' : '') or
		warn("Could not append to the ".SP_PVE_Q_LOG." logfile: $!\n");
	close $outf or warn("Could not close the ".SP_PVE_Q_LOG." logfile after appending to it: $!\n");
}

# HTTP request to the storpool api
sub sp_request($$$$){
	my ($cfg, $method, $addr, $params) = @_;
	
	return undef if ( ${^GLOBAL_PHASE} eq 'START' );

	my $h = HTTP::Headers->new;
	$h->header('Authorization' => 'Storpool v1:'.$cfg->{'api'}->{'auth_token'});
	
	my $p = HTTP::Request->new($method, $cfg->{'api'}->{'url'}.$addr, $h);
	$p->content( encode_json( $params ) ) if defined( $params );
	
	my $ua = new LWP::UserAgent;
	$ua->timeout(2 * 60 * 60);
	my $response = $ua->request($p);
	sp_request_log_response($cfg, $method, $addr, $response);
	if ($response->code eq "200"){
		return decode_json($response->content);
	}else{
		# this might break something
		my $res = decode_json($response->content);
		return $res if $res and $res->{'error'};
		return { 'error' => { 'descr' => 'Error code: '.$response->code} };
	}
}

sub sp_vol_create($$$$;$){
	my ($cfg, $size, $template, $ignoreError, $tags) = @_;
	
	my $req = { 'template' => $template, 'size' => $size, (defined($tags) ? (tags => $tags) : ()) };
	my $res = sp_post($cfg, "VolumeCreate", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_vol_status($) {
    my ($cfg) = @_;
	
	my $res = sp_get($cfg, "VolumesGetStatus");
	
	# If there is an error here it's fatal, we do not check.
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_volsnap_list($) {
    my ($cfg) = @_;
	
	my $res = sp_get($cfg, "VolumesAndSnapshotsList");
	
	# If there is an error here it's fatal, we do not check.
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_volsnap_list_with_cache($$) {
    my ($cfg, $cache) = @_;

    # pp: this will probably need another level for a multicluster setup some day
    $cache->{'storpool'}->{'volsnap'} //= sp_volsnap_list($cfg);
    $cache->{'storpool'}->{'volsnap'}
}

sub sp_vol_list($) {
    my ($cfg) = @_;
	my $res = sp_get($cfg, "VolumesList");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_vol_info($$) {
	my ($cfg, $global_id) = @_;
	
	my $res = sp_get($cfg, "Volume/~$global_id");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_vol_info_single($$) {
    my ($cfg, $global_id) = @_;

    my $res = sp_vol_info($cfg, $global_id);
    if (!defined($res->{'data'}) || ref($res->{'data'} ne 'ARRAY') || @{$res->{'data'}} != 1) {
        log_and_die("Internal StorPool error: expected exactly one volume with the $global_id global ID, got ".Dumper($res));
    }
    $res->{'data'}->[0]
}

sub sp_snap_info_single($$) {
    my ($cfg, $global_id) = @_;

    my $res = sp_snap_info($cfg, $global_id);
    if (!defined($res->{'data'}) || ref($res->{'data'} ne 'ARRAY') || @{$res->{'data'}} != 1) {
        log_and_die("Internal StorPool error: expected exactly one snapshot with the $global_id global ID, got ".Dumper($res));
    }
    $res->{'data'}->[0]
}

sub sp_snap_list($) {
    my ($cfg) = @_;
	
	my $res = sp_get($cfg, "SnapshotsList");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_attach_list($) {
    my ($cfg) = @_;
	my $res = sp_get($cfg, "AttachmentsList");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_snap_info($$) {
	my ($cfg, $snapname) = @_;
	
	my $res = sp_get($cfg, "Snapshot/~$snapname");
	#use Devel::StackTrace;
	#my $trace = Devel::StackTrace->new;
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_disk_list($) {
    my ($cfg) = @_;
	
	my $res = sp_get($cfg, "DisksList");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_temp_get($$) {
	my ($cfg, $name) = @_;
	
	my $res = sp_get($cfg, "VolumeTemplateDescribe/$name");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	return $res;
}

sub sp_temp_status($) {
    my ($cfg) = @_;
	
	my $res = sp_get($cfg, "VolumeTemplatesStatus");
	
	# If there is an error here it's fatal, we do not check.
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

#TODO, if adding more nodes, iso need to be attached to them as well
sub sp_vol_attach($$$$$;$$) {
	my ($cfg, $global_id, $spid, $perms, $ignoreError, $is_snapshot, $force_detach_all) = @_;
	
	my $res;
        my $keyword = $is_snapshot ? 'snapshot' : 'volume';
        my $req = [{
            $keyword => "~$global_id",
            $perms => [$spid],
            ($force_detach_all ? ('detach' => 'all', 'force' => JSON::true) : ()),
        }];
        $res = sp_post($cfg, "VolumesReassignWait", $req);
	
	die "Storpool: $global_id, $spid, $perms, $ignoreError: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	
	
	return $res
}

sub sp_vol_detach($$$$;$) {
	my ($cfg, $global_id, $spid, $ignoreError, $is_snapshot) = @_;
	
	my $req;
        my $keyword = $is_snapshot ? 'snapshot' : 'volume';
	if ($spid eq "all"){
		$req = [{ $keyword => "~$global_id", 'detach' => $spid, 'force' => JSON::false }];
	}else{
		$req = [{ $keyword => "~$global_id", 'detach' => [$spid], 'force' => JSON::false }];
	}
	my $res = sp_post($cfg, "VolumesReassignWait", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_vol_del($$$) {
	my ($cfg, $global_id, $ignoreError) = @_;
	
	my $req = {};
	my $res = sp_post($cfg, "VolumeDelete/~$global_id", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_vol_from_snapshot ($$$;$) {
	my ($cfg, $global_id, $ignoreError, $tags) = @_;
	
	my $req = { 'parent' => "~$global_id", 'tags' => $tags // '' };
	my $res = sp_post($cfg, "VolumeCreate", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_vol_from_parent_volume ($$$;$) {
	my ($cfg, $global_id, $ignoreError, $tags) = @_;
	
	my $req = { 'baseOn' => "~$global_id", 'tags' => $tags // '' };
	my $res = sp_post($cfg, "VolumeCreate", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

# Currently only used for resize
sub sp_vol_update ($$$$) {
	my ($cfg, $global_id, $req, $ignoreError) = @_;
	
	my $res = sp_post($cfg, "VolumeUpdate/~$global_id", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_services_list($) {
    my ($cfg) = @_;
	
	my $res = sp_get($cfg, "ServicesList");
	return $res;
}

sub sp_vol_snapshot($$$;$) {
	my ($cfg, $global_id, $ignoreError, $tags) = @_;
	
	# my $req = { 'name' => $snap };
        my $req = { tags => $tags // {}, };
	my $res = sp_post($cfg, "VolumeSnapshot/~$global_id", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_snap_del($$$) {
	my ($cfg, $global_id, $ignoreError) = @_;
	
	my $req = { };
	my $res = sp_post($cfg, "SnapshotDelete/~$global_id", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_placementgroup_list($$) {
	my ($cfg, $pg) = @_;
	
	my $res = sp_get($cfg, "PlacementGroupDescribe/$pg");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	return $res;
}

sub sp_client_sync($$) {
	my ($cfg, $client_id) = @_;

	my $res = sp_get($cfg, "ClientConfigWait/$client_id");

	die $res->{'error'}->{'descr'} if ($res->{'error'});
	return $res;
}

sub sp_vol_revert_to_snapshot($$$) {
    my ($cfg, $vol_id, $snap_id) = @_;

    my $req = { 'toSnapshot' => "~$snap_id", 'revertSize' => JSON::true };
    my $res = sp_post($cfg, "VolumeRevert/~$vol_id", $req);

    die "Storpool: ".$res->{'error'}->{'descr'} if $res->{'error'};
    return $res
}

sub sp_snap_not_gone($) {
    my ($snap) = @_;
	return substr(($snap->{'name'} // ''), 0, 1) ne '*'
}

sub sp_is_ours($$%) {
    my ($cfg, $vol, %named) = @_;

    sp_vol_tag_is($vol, VTAG_VIRT, VTAG_V_PVE) &&
    sp_vol_tag_is($vol, VTAG_LOC, sp_get_loc_name($cfg)) &&
    ($named{'any_storage'} || sp_vol_tag_is($vol, VTAG_STORE, $cfg->{'storeid'}))
}

sub sp_volume_find_snapshots($$$) {
    my ($cfg, $vol, $snap) = @_;

    grep {
        sp_snap_not_gone($_) &&
        sp_is_ours($cfg, $_) &&
        sp_vol_tag_is($_, VTAG_SNAP_PARENT, $vol->{'globalId'}) &&
        (!defined($snap) || sp_vol_tag_is($_, VTAG_SNAP, $snap))
    } @{sp_snap_list($cfg)->{'data'}}
}

# Delete all snapshot that are parents of the volume provided
sub sp_clean_snaps($$) {
    my ($cfg, $vol) = @_;

    for my $snap_obj (sp_volume_find_snapshots($cfg, $vol, undef)) {
        sp_snap_del($cfg, $snap_obj->{'globalId'}, 0);
    }
}

# Various name encoding helpers and utility functions

# Get the value of a tag for a volume.
#
# Returns an undefined value if the volume does not have that tag.
sub sp_vol_get_tag($ $) {
    my ($vol, $tag) = @_;

    ${$vol->{tags} // {}}{$tag}
}

# Check whether a volume has the specified tag, and that its value is as expected.
sub sp_vol_tag_is($ $ $) {
    my ($vol, $tag, $expected) = @_;
    my $value = sp_vol_get_tag($vol, $tag);

    defined($value) && $value eq $expected
}

# Check whether a content type denotes an image, either of a VM or of a container.
sub sp_type_is_image($) {
    my ($type) = @_;

    $type eq 'images' || $type eq 'rootdir'
}

sub sp_is_empty($) {
    my ($value) = @_;

    if (!defined $value) {
        return 1;
    }
    if ($value eq '') {
        return 1;
    }
    return 0;
}

sub sp_encode_volsnap_from_tags($) {
    my ($vol) = @_;
    my %tags = %{$vol->{'tags'}};
    
    my $global_id = do {
        if ($vol->{'snapshot'}) {
            $vol->{'globalId'}
        } else {
            if ($vol->{'name'} !~ RE_NAME_GLOBAL_ID) {
                log_and_die 'Only unnamed StorPool volumes supported: '.Dumper($vol);
            }
            $+{'global_id'}
        }
    };

    if ($tags{VTAG_TYPE()} eq 'iso') {
        if (!sp_is_empty($tags{VTAG_VM()}) ||
            !sp_is_empty($tags{VTAG_BASE()}) ||
            !sp_is_empty($tags{VTAG_SNAP()}) ||
            !sp_is_empty($tags{VTAG_SNAP_PARENT()})) {
            log_and_die 'An ISO image should not have the VM, base, snapshot, or snapshot parent tags: '.
                Dumper($vol);
        }
        if (!$vol->{'snapshot'}) {
            log_and_die 'An ISO image should be a StorPool snapshot: '.Dumper($vol);
        }

        return ($tags{VTAG_COMMENT()} // 'unlabeled')."-sp-$global_id.iso";
    }

    if (!sp_type_is_image($tags{VTAG_TYPE()})) {
        log_and_die 'Internal StorPool error: not an image: '.Dumper($vol);
    }

    if (!defined $tags{VTAG_VM()}) {
        if (!sp_is_empty($tags{VTAG_BASE()}) ||
            !sp_is_empty($tags{VTAG_SNAP()}) ||
            !sp_is_empty($tags{VTAG_SNAP_PARENT()})) {
            log_and_die 'A freestanding image should not have the base, snapshot, or snapshot parent tags: '.
                Dumper($vol);
        }
        if (!$vol->{'snapshot'}) {
            log_and_die 'A freestanding image should be a StorPool snapshot: '.Dumper($vol);
        }

        return 'img-'.($tags{VTAG_COMMENT()} // 'unlabeled')."-sp-$global_id.raw";
    }

    if ($tags{VTAG_BASE()}) {
        if (!sp_is_empty($tags{VTAG_SNAP()}) ||
            !sp_is_empty($tags{VTAG_SNAP_PARENT()})) {
            log_and_die 'A base disk image should not have the snapshot or snapshot parent tags: '.
                Dumper($vol);
        }
        if (!$vol->{'snapshot'}) {
            log_and_die 'A base disk image should be a StorPool snapshot: '.Dumper($vol);
        }
        if (sp_is_empty($tags{VTAG_DISK()})) {
            log_and_die 'A base disk image should specify a disk: '.Dumper($vol);
        }

        return "base-$tags{VTAG_VM()}-disk-$tags{VTAG_DISK()}-sp-$global_id.raw";
    }

    if ($tags{VTAG_SNAP()}) {
        if (sp_is_empty($tags{VTAG_DISK()})) {
            log_and_die 'A disk or VM state snapshot should specify a disk: '.Dumper($vol);
        }

        if ($tags{VTAG_DISK()} eq 'state') {
            if ($vol->{'snapshot'}) {
                log_and_die 'A VM state snapshot should be a StorPool volume: '.Dumper($vol);
            }

            if (!sp_is_empty($tags{VTAG_SNAP_PARENT()})) {
                log_and_die 'A VM state snapshot should not have the snapshot parent tag: '.Dumper($vol);
            }

            return "snap-$tags{VTAG_VM()}-state-$tags{VTAG_SNAP()}-sp-$global_id.raw";
        }

        if (!$vol->{'snapshot'}) {
            log_and_die 'A disk or VM state snapshot should be a StorPool snapshot: '.Dumper($vol);
        }
        if (sp_is_empty($tags{VTAG_SNAP_PARENT()})) {
            log_and_die 'A disk snapshot should have the snapshot parent tag: '.Dumper($vol);
        }

        return "snap-$tags{VTAG_VM()}-disk-$tags{VTAG_DISK()}".
            "-$tags{VTAG_SNAP()}-p-$tags{VTAG_SNAP_PARENT()}-sp-$global_id.raw";
    }

    if ($vol->{'snapshot'}) {
        log_and_die 'A disk image should be a StorPool volume: '.Dumper($vol);
    }
    if (sp_is_empty($tags{VTAG_DISK()})) {
        log_and_die 'A disk image should specify a disk: '.Dumper($vol);
    }

    return "vm-$tags{VTAG_VM()}-disk-$tags{VTAG_DISK()}-sp-$global_id.raw";
}

sub sp_decode_volsnap_to_tags($) {
    my ($volname) = @_;

    if ($volname =~ RE_VOLNAME_ISO) {
        my ($comment, $global_id) = ($+{'comment'}, $+{'global_id'});
        return {
            'name' => "~$global_id",
            'snapshot' => JSON::true,
            'globalId' => $global_id,
            'tags' => {
                VTAG_TYPE() => 'iso',
                VTAG_COMMENT() => $comment,
            },
        };
    }

    if ($volname =~ RE_VOLNAME_IMG) {
        my ($comment, $global_id) = ($+{'comment'}, $+{'global_id'});
        return {
            'name' => "~$global_id",
            'snapshot' => JSON::true,
            'globalId' => $global_id,
            'tags' => {
                VTAG_TYPE() => 'images',
                VTAG_COMMENT() => $comment,
            },
        };
    }

    if ($volname =~ RE_VOLNAME_SNAPSHOT) {
        my ($disk_id, $global_id, $parent_id, $snapshot, $vm_id) = ($+{'disk_id'}, $+{'global_id'}, $+{'parent_id'}, $+{'snapshot'}, $+{'vm_id'});
        return {
            'name' => "~$global_id",
            'snapshot' => JSON::true,
            'globalId' => $global_id,
            'tags' => {
                VTAG_TYPE() => 'images',
                VTAG_VM() => $vm_id,
                VTAG_DISK() => $disk_id,
                VTAG_SNAP() => $snapshot,
                VTAG_SNAP_PARENT() => $parent_id,
            },
        };
    }

    if ($volname =~ RE_VOLNAME_VMSTATE) {
        my ($global_id, $snapshot, $vm_id) = ($+{'global_id'}, $+{'snapshot'}, $+{'vm_id'});
        return {
            'name' => "~$global_id",
            'snapshot' => JSON::false,
            'globalId' => $global_id,
            'tags' => {
                VTAG_TYPE() => 'images',
                VTAG_VM() => $vm_id,
                VTAG_DISK() => 'state',
                VTAG_SNAP() => $snapshot,
            },
        };
    }

    if ($volname =~ RE_VOLNAME_BASE) {
        my ($disk_id, $global_id, $vm_id) = ($+{'disk_id'}, $+{'global_id'}, $+{'vm_id'});
        return {
            'name' => "~$global_id",
            'snapshot' => JSON::true,
            'globalId' => $global_id,
            'tags' => {
                VTAG_TYPE() => 'images',
                VTAG_VM() => $vm_id,
                VTAG_DISK() => $disk_id,
                VTAG_BASE() => JSON::true,
            },
        };
    }

    if ($volname =~ RE_VOLNAME_DISK) {
        my ($disk_id, $global_id, $vm_id) = ($+{'disk_id'}, $+{'global_id'}, $+{'vm_id'});
        return {
            'name' => "~$global_id",
            'snapshot' => JSON::false,
            'globalId' => $global_id,
            'tags' => {
                VTAG_TYPE() => 'images',
                VTAG_VM() => $vm_id,
                VTAG_DISK() => $disk_id,
            },
        };
    }

    log_and_die "Internal StorPool error: don't know how to decode ".Dumper(\$volname);
}

sub cfg_format_version($) {
    my ($raw) = @_;
    my $sect = $raw->{'format.version'};
    if (!defined $sect || ref $sect ne 'HASH') {
        die "No [$sect] section\n";
    }
    my ($major, $minor) = ($sect->{'major'}, $sect->{'minor'});
    if (!defined $major || !defined $minor) {
        die "Both $sect.major and $sect.minor must be defined\n";
    }
    if ($major !~ /^0 | (?: [1-9] [0-9]* )$/x || $minor !~ /^0 | (?: [1-9][0-9]* )$/x) {
        die "Both $sect.major and $sect.minor must be non-negative decimal numbers\n";
    }
    return ($major, $minor);
}

# Get some storpool settings from storpool.conf
sub sp_confget() {
    my %res;
    open my $f, '-|', 'storpool_confget' or log_and_die "Could not run storpool_confget: $!";
    while (<$f>) {
        chomp;
        my ($var, $value) = split /=/, $_, 2;
        $res{$var} = $value;
    }
    return %res;
}

sub cfg_load_fmtver($ $ $) {
    my ($fname, $major, $minor) = @_;

    my %raw;
    tie %raw, 'Config::IniFiles', (
        -file => $fname,
        -allowcontinue => 1,
    ) or die "Could not read the $fname file: $@\n";
    my @fmtver;
    eval {
        @fmtver = cfg_format_version(\%raw);
    };
    if ($@) {
        my $msg = $@;
        die "The format version check failed for the $fname file: $msg\n";
    };
    if ($fmtver[0] != $major || $fmtver[1] != $minor) {
        die "Only format version 0.1 supported for the present for the $fname file\n";
    }
    return %raw;
}

sub cfg_parse_api() {
    my %raw = sp_confget();
    my ($host, $port, $auth_token, $ourid) = @raw{qw(
        SP_API_HTTP_HOST
        SP_API_HTTP_PORT
        SP_AUTH_TOKEN
        SP_OURID
    )};
    if (!defined $host || !defined $port || !defined $auth_token || !defined $ourid) {
        log_and_die 'Incomplete StorPool configuration; need host, port, auth token, node id';
    }
    return {
        'auth_token' => $auth_token,
        'ourid' => $ourid,
        'url' => "http://$host:$port/ctrl/$SP_VERS/",
    };
}

sub sp_cfg($$) {
    my ($scfg, $storeid) = @_;

    return {
        'api' => cfg_parse_api(),
        'proxmox' => {
            'id' => {
                'name' => PVE::Cluster::get_clinfo()->{'cluster'}->{'name'},
            },
        },
        'storeid' => $storeid,
        'scfg' => $scfg,
    };
}

# Configuration

sub api {
    my $minver = 3;
    my $maxver = 10;

    # We kind of depend on the way `use constant` declares a function.
    # If we try to use barewords and not functions, the compiler will
    # throw a compile-time error, not a run-time one, which would
    # disable the whole plugin.

    my $apiver;
    eval {
        $apiver = PVE::Storage::APIVER();
    };
    if ($@) {
        # Argh, they don't even declare APIVER? Well... too bad.
        return $minver;
    }

    my $apiage;
    eval {
        $apiage = PVE::Storage::APIAGE();
    };
    if ($@) {
        # Hm, no APIAGE? OK, is their version within our range?
        if ($apiver >= $minver && $apiver <= $maxver) {
            return $apiver;
        }

        # Ah well...
        return $minver;
    }

    # Is our version within their declared supported range?
    if ($apiver >= $maxver && $apiver <= $maxver + $apiage) {
        return $maxver;
    }

    # This is a bit of a lie, but, well...
    if ($apiver <= $maxver) {
        return $apiver;
    }

    # Oof. This is fun.
    return $minver;
}

# This is the most important method. The ID of the plugin
sub type {
    return 'storpool';
}

# The capabilities of the plugin
sub plugindata {
    
    return {
	content => [ { images => 1, rootdir => 1, iso => 1, backup => 1, none => 1 },
		     { images => 1,  rootdir => 1 }],
	format => [ { raw => 1 } , 'raw' ],
    };
}   

# The properties the plugin can handle
sub properties {

    return {
	'extra-tags' => {
	    description => 'Additional tags to add to the StorPool volumes and snapshots',
	    type => 'string',
	},
	'template' => {
	    description => 'The StorPool template to use, if different from the storage name',
	    type => 'string',
	},
    };
}

sub options {

    return {
        nodes => { optional => 1 },
	shared => { optional => 1 },
	disable => { optional => 1 },
        maxfiles => { optional => 1 },
	content => { optional => 1 },
	format => { optional => 1 },
	'extra-tags' => { optional => 1 },
    template => { optional => 1 },
   };
}

# Storage implementation

# Just check value before accepting the request
PVE::JSONSchema::register_format('pve-storage-replication', \&sp_parse_replication);
sub sp_parse_replication {
    my ($rep, $noerr) = @_;

    if ($rep < 1 or $rep > 4) {
	return undef if $noerr;
	die "replication must be between 1 and 4\n";
    }

    return $rep;
}

# This creates the storpool template. It's called frequently though,
# so we ignore "already exists" errors
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    
    sp_temp_get($cfg, sp_get_template($cfg));
}

sub sp_get_tags($) {
    my ($cfg) = @_;

    my $extra_spec = $cfg->{'scfg'}->{'extra-tags'} // '';
    my %extra_tags = map { split /=/, $_, 2 } split /\s+/, $extra_spec;
    return (
        VTAG_VIRT() => VTAG_V_PVE,
        VTAG_LOC() => sp_get_loc_name($cfg),
        VTAG_STORE() => $cfg->{'storeid'},
        %extra_tags,
    );
}

sub sp_get_template($) {
    my ($cfg) = @_;

    return $cfg->{'scfg'}->{'template'} // $cfg->{'storeid'};
}

sub sp_get_loc_name($) {
    my ($cfg) = @_;

    return $cfg->{'proxmox'}->{'id'}->{'name'};
}

sub find_free_disk($ $) {
    my ($cfg, $vm_id) = @_;

    # OK, maybe there might be a better way to do this some day...
    my $lst = sp_volsnap_list($cfg);
    my $disk_id = 0;
    for my $vol (@{$lst->{'data'}->{'volumes'}}) {
        next unless sp_is_ours($cfg, $vol, any_storage => 1) &&
            ($vol->{'tags'}->{VTAG_VM()} // '') eq $vm_id;

        my $current_str = $vol->{'tags'}->{VTAG_DISK()};
        if (defined $current_str && $current_str ne 'state') {
            my $current = int $current_str;
            if ($current >= $disk_id) {
                $disk_id = $current + 1;
            }
        }
    }
    return $disk_id;
}

# Create the volume
sub alloc_image {
	my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
        my $cfg = sp_cfg($scfg, $storeid);

	# One of the few places where size is in K
	$size *= 1024;
	die "unsupported format '$fmt'" if $fmt ne 'raw';

	
    my %extra_tags = do {
        if (defined $name && $name =~ RE_VOLNAME_PROXMOX_VMSTATE) {
            my ($state_snapshot, $state_vmid) = ($+{'snapshot'}, $+{'vm_id'});
            if ($state_vmid ne $vmid) {
                log_and_die "Inconsistent VM snapshot state name: passed in VM id $vmid and name $name\n";
            }
            (
                VTAG_VM() => $state_vmid,
                VTAG_DISK() => 'state',
                VTAG_SNAP() => $state_snapshot,
            )
        } elsif (defined $vmid) {
            my $disk_id = find_free_disk($cfg, $vmid);
            (
                VTAG_VM() => "$vmid",
                VTAG_DISK() => "$disk_id",
            )
        } else {
            ()
        }
    };

	my $c_res = sp_vol_create($cfg, $size, sp_get_template($cfg), 0, {
            sp_get_tags($cfg),
            VTAG_TYPE() => 'images',
            %extra_tags,
        });
        my $global_id = ($c_res->{'data'} // {})->{'globalId'};
        if (!defined($global_id) || $global_id eq '') {
            log_and_die 'StorPool internal error: no globalId in the VolumeCreate API response: '.Dumper($c_res);
        }

        my $vol = sp_vol_info_single($cfg, $global_id);
        sp_encode_volsnap_from_tags($vol);
}

# Status of the space of the storage
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    
    my $name = sp_get_template($cfg);
    my @ours = grep { $_->{'name'} eq $name} @{sp_temp_status($cfg)->{'data'}};
    if (@ours != 1) {
        log_and_die "StorPool internal error: expected exactly one '$name' entry in the 'template status' output, got ".Dumper(\@ours);
    }

    my ($capacity, $free) = ($ours[0]->{'stored'}->{'capacity'}, $ours[0]->{'stored'}->{'free'});
    return ($capacity, $free, $capacity - $free, 1);
}

sub parse_volname ($) {
    my ($class, $volname) = @_;

    my $vol = sp_decode_volsnap_to_tags($volname);

    return (
        $vol->{'tags'}->{VTAG_TYPE()},
        $vol->{'globalId'},
        $vol->{'tags'}->{VTAG_VM()},
        undef,
        undef,
        ($vol->{'tags'}->{VTAG_BASE()} // '0') eq '1',
        'raw',
    )
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname("$volname");
    
    my $path = "/dev/storpool-byid/$name";

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub get_vm_status {
    my ($vmid) = @_;
    my $all_vms = do {
        open(my $f, '-|', 'pvesh', 'get', 'cluster/resources', '-type', 'vm', '--output-format', 'json') or log_and_die("pvesh failed: $!");
        my $pvesh_output = do {
            local $/;
            <$f>
        };
        my $status = decode_json($pvesh_output);
        close($f) or log_and_die($! == 0 ? "pvesh exited with code $?" : "reading pvesh output failed: $!");
        $status;
    };
    my $vm_status = first { $_->{"vmid"} == $vmid } @{$all_vms} or log_and_die("Could not find VM $vmid in cluster resources");
    log_info("VM $vmid parsed status:\n".Dumper($vm_status));
    return $vm_status;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $exclusive, $cache) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
	
    my $path = $class->path($scfg, $volname, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    my $global_id = $vol->{'globalId'};

    my $perms = $vol->{'snapshot'} ? 'ro' : 'rw';

    my $vmid = $vol->{'tags'}->{VTAG_VM()};
    my $force_detach = 0;
    if (!sp_is_empty($vmid)) {
        log_info("Volume $vol->{'name'} is related to VM $vmid, checking status");
        my $vm_status = get_vm_status($vmid);
        if (($vm_status->{'lock'} // '') ne 'migrate' && ($vm_status->{'hastate'} // '') ne 'migrate') {
            log_info("NOT a live migration of VM $vmid, will force detach volume $vol->{'name'}");
            $force_detach = 1;
        } else {
            log_info("Live migration of VM $vmid, will not force detach volume $vol->{'name'}");
        }
    } else {
        log_info("Volume $vol->{'name'} is not related to a VM, not checking status");
    }

    # TODO: pp: remove this when the configuration goes into the plugin?
    sp_vol_attach($cfg, $global_id, $cfg->{'api'}->{'ourid'}, $perms, 0, $vol->{'snapshot'}, $force_detach);
    log_and_die "Internal StorPool error: could not find the just-attached volume $global_id at $path" unless -e $path;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $cache) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    
    my $path = $class->path($scfg, $volname, $storeid);
    
    return if ! -b $path;

    my $vol = sp_decode_volsnap_to_tags($volname);
    my $global_id = $vol->{'globalId'};

    # TODO: pp: remove this when the configuration goes into the plugin?
    sp_vol_detach($cfg, $global_id, $cfg->{'api'}->{'ourid'}, 0, $vol->{'snapshot'});
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    my $vol = sp_decode_volsnap_to_tags($volname);
    my ($global_id, $is_snapshot) = ($vol->{'globalId'}, $vol->{'snapshot'});

    # Volume could already be detached, we do not care about errors
    sp_vol_detach($cfg, $global_id, 'all', 1, $is_snapshot);

    if ($is_snapshot) {
        sp_snap_del($cfg, $global_id, 0);
    } else {
        sp_vol_del($cfg, $global_id, 0);
        sp_clean_snaps($cfg, $vol);
    }
    
    return undef;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
	snapshot => { current => 1, snap => 1 },
	clone => { base => 1, current => 1, snap => 1 },
	template => { current => 1 },
	copy => { base => 1,
		  current => 1,
		  snap => 1 },
        rename => { current => 1, },
        sparseinit => { base => 1, current => 1, snap => 1 },
    };

    my ($vtype, $name, $vmid, , undef, undef, $isBase) =
	$class->parse_volname($volname);

    my $key = undef;
    if($snapname){
        $key = 'snap';
    }else{
        $key =  $isBase ? 'base' : 'current';
    }

    return 1 if defined($features->{$feature}->{$key});

    return undef;
}

#sub file_size_info {
#    my ($filename, $timeout) = @_;
#}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    
    my $vol = sp_decode_volsnap_to_tags($volname);
    
    my $res = sp_vol_status($cfg);
    my @vol_status = grep { $_->{'name'} eq $vol->{'name'} } values %{$res->{'data'}};
    if (@vol_status != 1) {
        log_and_die "Internal StorPool error: expected exactly one $vol->{name} volume: ".Dumper(\@vol_status);
    }

    # Right. So Proxmox seems to need these to be validated.
    my ($size, $used) = ($vol_status[0]->{'size'}, $vol_status[0]->{'storedSize'});
    if ($size =~ /^ (?P<size> 0 | [1-9][0-9]* ) $/x) {
        $size = $+{'size'};
    } else {
        log_and_die "Internal error: unexpected size '$size' for $volname";
    }
    if ($used =~ /^ (?P<size> 0 | [1-9][0-9]* ) $/x) {
        $used = $+{'size'};
    } else {
        log_and_die "Internal error: unexpected storedSize '$used' for $volname";
    }

    # TODO: pp: do we ever need to support anything other than 'raw' here?
    return wantarray ? ($size, 'raw', $used, undef) : $size;

}

sub list_volumes_with_cache {
    my ($class, $storeid, $scfg, $vmid, $content_types, $cache) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    my %ctypes = map { $_ => 1 } @{$content_types};

    my $volStatus = sp_volsnap_list_with_cache($cfg, $cache);
    my $res = [];

    for my $vol (@{$volStatus->{'data'}->{'volumes'}}) {
        next unless sp_is_ours($cfg, $vol);
        my $v_type = sp_vol_get_tag($vol, VTAG_TYPE);
        next unless defined($v_type) && exists $ctypes{$v_type};

        my $v_vmid = sp_vol_get_tag($vol, VTAG_VM);
        if (defined $vmid) {
            next unless defined($v_vmid) && $v_vmid eq $vmid;
        }

        # TODO: pp: apply the rootdir/images fix depending on $v_vmid

        # TODO: pp: figure out whether we ever need to store non-raw data on StorPool
        my $data = {
            volid => "$storeid:".sp_encode_volsnap_from_tags($vol),
            content => $v_type,
            vmid => $v_vmid,
            size => $vol->{size},
            used => $vol->{storedSize},
            parent => undef,
            format => 'raw',
        };
        push @{$res}, $data;
    }

    return $res;
}

sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;
    return list_volumes_with_cache($class, $storeid, $scfg, $vmid, $content_types, {});
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    if (defined $vollist) {
        log_and_die "TODO: list_images() with a volume list not implemented yet: ".Dumper(\$vmid, $vollist);
    }

    # pp: possibly optimize for the "only a single ID in @{$vollist}" case... maybe
    return $class->list_volumes_with_cache($storeid, $scfg, $vmid, [keys %{$scfg->{content}}], $cache);
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    my ($global_id, $vtype) = ($vol->{'globalId'}, $vol->{tags}->{VTAG_TYPE()});
    # my ($vtype, $name, $vmid, undef, undef, $isBase) =
	# $class->parse_volname($volname);
    die "create_base not possible with types other than images. '$vtype' given.\n" if $vtype ne 'images';

    die "create_base not possible with base image\n" if $vol->{tags}->{VTAG_BASE()};
	
    # my ($size, $format, $used, $parent) = $class->volume_size_info($scfg, $storeid, $volname, 0);
    # die "file_size_info on '$volname' failed\n" if !($format && $size);

    # die "volname '$volname' contains wrong information about parent\n"
	# if $isBase && !$parent;

    # my $newname = $name;
    # $newname =~ s/^vm-/base-/;

    my $current_tags = (
        $vol->{'snapshot'}
            ? sp_snap_info_single($cfg, $vol->{'globalId'})
            : sp_vol_info_single($cfg, $vol->{'globalId'})
    )->{'tags'} // {};

    my $snap_res = sp_vol_snapshot($cfg, $global_id, 0, {
        %{$current_tags},
        VTAG_BASE() => "1",
    });

    my $snap_id = $snap_res->{'data'}->{'snapshotGlobalId'};
    my $snap = sp_snap_info_single($cfg, $snap_id);

    sp_vol_detach($cfg, $global_id, 'all', 0);
    sp_vol_del($cfg, $global_id, 0);

    return sp_encode_volsnap_from_tags($snap);
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    if ($snap) {
        my @found = sp_volume_find_snapshots($cfg, $vol, $snap);
        if (@found != 1) {
            log_and_die "Expected exactly one StorPool snapshot for $vol / $snap, got ".Dumper(\@found);
        }

        # OK, let's go wild...
        $vol = $found[0];
    }

    my ($global_id, $vtype, $isBase) = (
        $vol->{'globalId'},
        $vol->{'tags'}->{VTAG_TYPE()},
        $vol->{'tags'}->{VTAG_BASE()},
    );

    die "clone_image on wrong vtype '$vtype'\n" if $vtype ne 'images';


    my $updated_tags = sub {
        my ($current_tags) = @_;
        my $disk_id;
        if (defined $current_tags->{VTAG_DISK()}) {
            $disk_id = find_free_disk($cfg, $vmid);
        }

        return {
            %{$current_tags},
            VTAG_BASE() => '0',
            VTAG_VM() => "$vmid",
            (defined $disk_id ? (VTAG_DISK() => "$disk_id") : ()),
        };
    };

    my $c_res;
    if ($vol->{'snapshot'}) {
        my $current_tags = sp_snap_info_single($cfg, $vol->{'globalId'})->{'tags'} // {};
        $c_res = sp_vol_from_snapshot($cfg, $global_id, 0, $updated_tags->($current_tags));
    } else {
        my $current_tags = sp_vol_info_single($cfg, $vol->{'globalId'})->{'tags'} // {};
        $c_res = sp_vol_from_parent_volume($cfg, $global_id, 0, $updated_tags->($current_tags));
    }

    my $newvol = sp_vol_info_single($cfg, $c_res->{'data'}->{'globalId'});
    return sp_encode_volsnap_from_tags($newvol);
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;
    my $cfg = sp_cfg($scfg, $storeid);


    my $vol = sp_decode_volsnap_to_tags($volname);
    sp_vol_update($cfg, $vol->{'globalId'}, { 'size' => $size }, 0);

    # Make sure storpool_bd has told the kernel to update
    # the attached volume's size if needed
    my $res = sp_client_sync($cfg, $cfg->{'api'}->{'ourid'});

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    log_and_die "deactivate_storage($storeid) not implemented yet";

    #TODO this does NOT occur when deleting a storage
    
}

sub check_connection {
    my ($class, $storeid, $scfg) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    my $res = sp_services_list($cfg);
    die "Could not fetch the StorPool services list\n" if ! defined $res;
    die "Could not fetch the StorPool services list: ".$res->{'error'}."\n" if $res->{'error'};
    return 1;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    sp_vol_snapshot($cfg, $vol->{'globalId'}, 0, {
        %{$vol->{tags}},
        sp_get_tags($cfg),
        VTAG_SNAP() => $snap,
        VTAG_SNAP_PARENT() => $vol->{'globalId'},
    });

    return undef;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    for my $snap_obj (sp_volume_find_snapshots($cfg, $vol, $snap)) {
        sp_snap_del($cfg, $snap_obj->{'globalId'}, 0);
    }

    return undef;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    my @found = sp_volume_find_snapshots($cfg, $vol, $snap);
    if (@found != 1) {
        log_and_die "volume_snapshot_rollback: expected exactly one '$snap' snapshot for $vol->{globalId}, got ".Dumper(\@found);
    }

    my $snap_obj = $found[0];
    sp_vol_detach($cfg, $vol->{'globalId'}, 'all', 0);
    sp_vol_revert_to_snapshot($cfg, $vol->{'globalId'}, $snap_obj->{'globalId'});
    
    return undef;
}

sub volume_snapshot_needs_fsfreeze {
    return 1;
}

sub get_subdir {
    my ($class, $scfg, $vtype) = @_;
    log_and_die "get_subdir($vtype) not implemented yet";
}

sub delete_store {
	my ($class, $storeid) = @_;
        my $cfg = sp_cfg({}, $storeid);
    log_and_die "delete_store($storeid) not implemented yet";
	my $vols_hash = sp_vol_list($cfg);
	my $snaps_hash = sp_snap_list($cfg);
	my $atts_hash = sp_attach_list($cfg);

        my %attachments = map { ($_->{volume}, 1) } @{$atts_hash->{'data'}};

	foreach my $vol (@{$vols_hash->{data}}){
                next unless sp_vol_tag_is($vol, VTAG_VIRT, VTAG_V_PVE) &&
                    sp_vol_tag_is($vol, VTAG_LOC, sp_get_loc_name($cfg));
                next unless $vol->{'templateName'} eq sp_get_template($cfg);
                if ($attachments{$vol->{'name'}}) {
                        sp_vol_detach($cfg, $vol->{'globalId'}, 'all', 0);
                }
                sp_vol_del($cfg, $vol->{'globalId'}, 0);
	}

	foreach my $snap (@{$snaps_hash->{data}}){
                next unless sp_snap_not_gone($snap);
                next unless sp_vol_tag_is($snap, VTAG_VIRT, VTAG_V_PVE) &&
                    sp_vol_tag_is($snap, VTAG_LOC, sp_get_loc_name($cfg));
                next unless $snap->{'templateName'} eq sp_get_template($cfg);
                if ($attachments{$snap->{'name'}}) {
                        sp_vol_detach($snap->{'globalId'}, 'all', 0, 1);
                }
                sp_snap_del($cfg, $snap->{'globalId'},0);
	}
}

sub rename_volume($$$$$$) {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($source_volname);
    sp_vol_update($cfg, $vol->{'globalId'}, {
        'tags' => {
            %{$vol->{'tags'}},
            VTAG_VM() => $target_vmid,
        },
    }, 0);

    my $updated = sp_vol_info_single($cfg, $vol->{'globalId'});
    "$storeid:".sp_encode_volsnap_from_tags($updated)
}

1;
#TODO when creating new storage, fix placementgroups
#TODO detach on normal shutdown (maybe done)
#TODO reattach iso after reboot
#misc TODO
# remove "raw" from interface make storage!   
#full clone (dropped)
#TODO clean sectionconfig.pm
