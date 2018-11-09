# debhelper buildsystem for Rust crates using Cargo
#
# Josh Triplett <josh@joshtriplett.org>
# Ximin Luo <infinity0@debian.org>

package Debian::Debhelper::Buildsystem::cargo;

use strict;
use warnings;
use Cwd;
use Debian::Debhelper::Dh_Lib;
use Dpkg::Changelog::Debian;
use Dpkg::Control::Info;
use Dpkg::Version;
use JSON::PP;
use base 'Debian::Debhelper::Buildsystem';

sub DESCRIPTION {
    "Rust Cargo"
}

sub cargo_version {
    my $src = shift;
    open(F, "cargo metadata --manifest-path $src --no-deps --format-version 1 |");
    local $/;
    my $json = JSON::PP->new;
    my $manifest = $json->decode(<F>);
    return %{@{%{$manifest}{'packages'}}[0]}{'version'} . "";
}

sub deb_host_rust_type {
    open(F, 'printf "include /usr/share/rustc/architecture.mk\n\
all:\n\
	echo \$(DEB_HOST_RUST_TYPE)\n\
" | make --no-print-directory -sf - |');
    $_ = <F>;
    chomp;
    return $_;
}

sub check_auto_buildable {
    my $this = shift;
    if (-f $this->get_sourcepath("Cargo.toml")) {
        return 1;
    }
    return 0;
}

sub new {
    my $class = shift;
    my $this = $class->SUPER::new(@_);
    $this->enforce_in_source_building();
    return $this;
}

sub pre_building_step {
    my $this = shift;
    my $step = shift;

    $this->{cargo_home} = Cwd::abs_path($this->get_sourcepath("debian/cargo_home"));
    $this->{host_rust_type} = deb_host_rust_type;

    my $control = Dpkg::Control::Info->new();

    my $source = $control->get_source();
    my $crate = $source->{'X-Cargo-Crate'};
    if (!$crate) {
        $crate = $source->{Source};
        $crate =~ s/^rust-//;
        $crate =~ s/-[0-9]+(\.[0-9]+)*$//;
    }
    $this->{crate} = $crate;
    my $changelog = Dpkg::Changelog::Debian->new(range => { count => 1 });
    $changelog->load($this->get_sourcepath("debian/changelog"));
    $this->{version} = Dpkg::Version->new(@{$changelog}[0]->get_version())->version();

    my @packages = $control->get_packages();
    $this->{libpkg} = 0;
    $this->{binpkg} = 0;
    $this->{featurepkg} = [];
    foreach my $package (@packages) {
        if ($package->{Package} =~ /^librust-.*-dev$/) {
            if ($package->{Package} =~ /\+/) {
                push(@{$this->{featurepkg}}, $package->{Package});
                next;
            }
            if ($this->{libpkg}) {
                error("Multiple Cargo lib packages found: " . $this->{libpkg} . " and " . $package->{Package});
            }
            $this->{libpkg} = $package->{Package};
        } elsif ($package->{Architecture} ne 'all') {
            $this->{binpkg} = $package->{Package};
        }
    }
    if (!$this->{libpkg} && !$this->{binpkg}) {
        error("Could not find any Cargo lib or bin packages to build.");
    }
    if (@{$this->{featurepkg}} && !$this->{libpkg}) {
        error("Found feature packages but no lib package.");
    }

    my $parallel = $this->get_parallel();
    $this->{j} = $parallel > 0 ? ["-j$parallel"] : [];

    $ENV{'CARGO_HOME'} = $this->{cargo_home};
    $ENV{'DEB_CARGO_CRATE'} = $crate . '_' . $this->{version};
    $ENV{'DEB_HOST_RUST_TYPE'} = $this->{host_rust_type};
    $ENV{'DEB_HOST_GNU_TYPE'} = dpkg_architecture_value("DEB_HOST_GNU_TYPE");

    $this->SUPER::pre_building_step($step);
}

sub get_sources {
    my $this=shift;
    opendir(my $dirhandle, $this->get_sourcedir());
    my @sources = grep { $_ ne '.' && $_ ne '..' && $_ ne '.git' && $_ ne '.pc' && $_ ne 'debian' } readdir($dirhandle);
    push @sources, 'debian/patches' if -d $this->get_sourcedir() . '/debian/patches';
    closedir($dirhandle);
    @sources
}

sub configure {
    my $this=shift;
    doit("cp", $this->get_sourcepath("debian/cargo-checksum.json"),
               $this->get_sourcepath(".cargo-checksum.json"));
    doit("/usr/share/cargo/bin/cargo", "prepare-debian", "/usr/share/cargo/registry");
}

sub test {
    my $this=shift;
    my $cmd="build";
    if (!defined $_[0]) {
        # nop
    } elsif ($_[0] eq "test") {
        $cmd="test";
        shift;
    } elsif ($_[0] eq "build") {
        shift;
    }
    # Check that the thing compiles. This might fail if e.g. the package
    # requires non-rust system dependencies and the maintainer didn't provide
    # this additional information to debcargo.
    doit("/usr/share/cargo/bin/cargo", $cmd, @_);
    # test generating Built-Using fields
    doit("env", "CARGO_CHANNEL=debug", "/usr/share/cargo/dh-cargo-built-using");
}

sub install {
    my $this=shift;
    my $destdir=shift;
    my $crate = $this->{crate} . '-' . $this->{version};
    if ($this->{libpkg}) {
        my $target = $this->get_sourcepath("debian/" . $this->{libpkg} . "/usr/share/cargo/registry/$crate");
        my @sources = $this->get_sources();
        doit("mkdir", "-p", $target);
        doit("cp", "--parents", "-at", $target, @sources);
        doit("rm", "-rf", "$target/target");
        doit("cp", $this->get_sourcepath("debian/cargo-checksum.json"), "$target/.cargo-checksum.json");
        # work around some stupid ftpmaster rule about files with old dates.
        doit("touch", "-d@" . $ENV{SOURCE_DATE_EPOCH}, "$target/Cargo.toml");
    }
    foreach my $pkg (@{$this->{featurepkg}}) {
        my $target = $this->get_sourcepath("debian/$pkg/usr/share/doc");
        doit("mkdir", "-p", $target);
        doit("ln", "-s", $this->{libpkg}, "$target/$pkg");
    }
    if ($this->{binpkg}) {
        # Do the install
        $ENV{'DEB_CARGO_PACKAGE'} = $this->{binpkg};
        doit("/usr/share/cargo/bin/cargo", "install", @_);
        # generate Built-Using fields
        doit("/usr/share/cargo/dh-cargo-built-using", $this->{binpkg});
    }
}

sub clean {
    my $this=shift;
    doit("/usr/share/cargo/bin/cargo", "clean", @_);
    doit("rm", "-rf", $this->get_sourcepath(".cargo-checksum.json"));
}

1
