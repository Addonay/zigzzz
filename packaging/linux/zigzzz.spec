# Packages a prebuilt, statically linked release binary; packaging/package.sh
# stages the sources and calls rpmbuild with:
#
#   --define "pkg_version <version>"   from build.zig.zon
#   --define "stage <directory>"       holding zigzzz, the desktop file,
#                                      icons/, and licenses/
#   --target x86_64 | aarch64
#
# Zig cross-compiles the binary, so rpmbuild must not strip it or extract
# debug info with host tools.

%global debug_package %{nil}
%global __strip /bin/true
%global _build_id_links none

Name:           zigzzz
Version:        %{pkg_version}
Release:        1
Summary:        Workspace
License:        LicenseRef-Proprietary AND Apache-2.0 AND OFL-1.1 AND ISC AND LGPL-3.0-or-later AND GPL-3.0-only
URL:            https://github.com/Addonay/zigzzz

# SDL3, SDL_image, FreeType, and Expat are linked in; only glibc is needed.
# X11/Wayland and the GPU drivers are loaded at runtime from the desktop.
AutoReqProv:    no
Requires:       glibc >= 2.31

%description
zigzzz — Workspace.

%install
install -Dm755 %{stage}/zigzzz %{buildroot}%{_bindir}/zigzzz
install -Dm644 %{stage}/io.github.addonay.zigzzz.desktop %{buildroot}%{_datadir}/applications/io.github.addonay.zigzzz.desktop

for size in 16 24 32 48 64 128 256 512; do
    install -Dm644 %{stage}/icons/zigzzz-$size.png \
        %{buildroot}%{_datadir}/icons/hicolor/${size}x${size}/apps/io.github.addonay.zigzzz.png
done

install -d %{buildroot}%{_datadir}/licenses/%{name}
install -m644 %{stage}/licenses/* %{buildroot}%{_datadir}/licenses/%{name}/

%files
%{_bindir}/zigzzz
%{_datadir}/applications/io.github.addonay.zigzzz.desktop
%{_datadir}/icons/hicolor/*/apps/io.github.addonay.zigzzz.png
%{_datadir}/licenses/%{name}/
