PkgBase       := "ceph"
ChrootPath    := env_var("HOME") / "chroot"
ChrootBase    := ChrootPath / "root"
ChrootActive  := ChrootPath / PkgVer + "_" + PkgRel
Scripts       := justfile_directory() / "scripts"

Color         := env_var_or_default("USE_COLOR", "1")
Chroot        := env_var_or_default("USE_CHROOT", "1")

# Default to listing recipes
_default:
  @just --list --list-prefix '  > '

# Build the package in a clean chroot
build:
  @$Say Building @{{PkgBuild}} via chroot
  makechrootpkg -c -r {{ChrootPath}} -d "/tmp:/tmp" -C -n -l {{PkgVer}}_{{PkgRel}}

# Create and update the base chroot
chroot: (_update_chroot ChrootBase)

# Initialize the base chroot for building packages
mkchroot: (_mkchroot ChrootBase)

# Watch build log streams, optionally filtering them with the given regex and options
watch $filter=None $opts="-iP": _mkloglist
  @$Say Watching build {{BuildTriple}} logs ${filter:+"(filter: $filter $opts)"}
  tail -F -n +1 --silent $(cat {{LogFileList}} | xargs) 2>/dev/null {{ if filter == None { None } else { '| rg ' + opts + ' "' + filter + '"' } }}

# Print build logs, optionally filtering them with the given regex and options
logs $filter=None $opts="-iP": _mkloglist
  @$Say Printing {{BuildTriple}} logs ${filter:+"(filter: $filter $opts)"}
  cat *.log 2>/dev/null {{ if filter == None { None } else { '| rg ' + opts + ' "' + filter + '"' } }}

# Install required dependencies
deps:
  pacman -S base-devel sudo devtools ripgrep --needed --noconfirm

# Clean one or more of: chroot|deps|artifacts|logs
clean +what="chroot":
  #!/usr/bin/env bash
  set -euo pipefail

  $Say "cleaning directive(s): {{what}}"
  for item in {{what}}; do
    case $item in
      chroot|c)
        (set -x; rm -rf {{ChrootActive}})
      ;;
      deps|d)
        (set -x; pacman -Rsc devtools --needed --noconfirm)
      ;;
      artifacts|a)
        (set -x; rm -vf *tar.*)
      ;;
      logs|l)
        (set -x; rm -vf *.log)
      ;;
      *)
        $Say unknown clean directive $item, ignoring
      ;;
    esac
  done

# Upload built artifacts to Github, using the associated release
upload pkg="ceph,ceph-libs,ceph-mgr": (_upload pkg)

# Initialize the chroot
@_mkchroot $cbase:
  {{ if path_exists(cbase) == "true" { ":" } else { "$Say Initializing chroot @$cbase" } }}
  {{ if path_exists(cbase) == "true" { ":" } else { "mkarchroot $cbase base-devel" } }}

# Update dependencies in the base chroot
@_update_chroot $cbase: (_mkchroot cbase)
  $Say Updating chroot packages @$cbase
  arch-nspawn $cbase pacman -Syu

@_mkloglist:
  mkdir -p $(dirname {{LogFileList}})
  echo \
    ceph-{{BuildTriple}}-{build,prepare,check,package_ceph{,-libs,-mgr}}.log \
    ceph-{,mgr-,libs-}{{BuildTriple}}.pkg.tar.zst-namcap.log \
    PKGBUILD-namcap.log \
    > {{LogFileList}}

# Script to upload a comma separated list of packages to the active Github release
_upload $pkgstring:
  #!/usr/bin/env bash
  set -euo pipefail

  [[ -n "$GITHUB_TOKEN" ]] || { $Say "Error: GITHUB_TOKEN must be set" && exit 4; }

  IFS=', ' read -r -a PKGS <<<"$pkgstring"

  $Say "uploading package(s): { ${PKGS[@]} } to {{GithubRepo}}/releases/v{{PkgVer}}-{{PkgRel}}"

  declare -A FILES
  for pkg in "${PKGS[@]}"; do
    fname="$pkg-{{PkgVer}}-{{PkgRel}}-{{PkgArch}}.pkg.tar.zst"
    [[ -f "$fname" ]] || { $Say "Error: unable to locate artifact '$fname' for '$pkg' upload" && exit 7; }
    FILES[$pkg]=$fname
  done

  for pkg in "${!FILES[@]}"; do
    src=${FILES[$pkg]}
    mime="$(file -b --mime-type $src)"
    dst="${pkg//-/_}_linux_{{PkgArch}}.tar.$(basename $mime)"

    $Say "uploading '$src' as '$dst'"

    {{Scripts}}.gh-upload-artifact.sh \
      ${DryRun:+--dry-run} \
      --repo {{GithubRepo}} \
      --tag v{{PkgVer}}-{{PkgRel}} \
      --file "$src:$dst"
  done

# ~~~ Global shell variables ~~~
export Say              := "echo " + C_RED + "==> " + C_RESET + BuildId
export DryRun           := None
export Debug            := None

# Nicer name for empty strings
None := ""

# ~~~ Contextual information ~~~
PkgBuild                := justfile_directory() / "PKGBUILD"
PkgVer                  := `awk -F= '/pkgver=/ {print $2}' PKGBUILD`
PkgRel                  := `awk -F= '/pkgrel=/ {print $2}' PKGBUILD`
PkgArch                 := 'x86_64'
GitCommitish            := if `git tag --points-at HEAD` != None {
                              `git tag --points-at HEAD`
                           } else if `git branch --show-current` != None {
                              `git branch --show-current`
                           } else {
                              `git rev-parse --short HEAD`
                           }
BuildId                 := "[" + C_YELLOW + PkgBase + C_RESET + "/" + C_GREEN + PkgVer + ":" + PkgRel + C_RESET + "@" + C_CYAN + GitCommitish + C_RESET + "]"
BuildTriple             := PkgVer + "-" + PkgRel + "-" + "x86_64"
LogFileList             := env_var_or_default("TEMP", "/tmp") / PkgBase + ".temp" / "logfiles"
GithubRepo              := "bazaah/aur-ceph"

# ~~~ Color Codes ~~~
C_ENABLED   := if Color =~ '(?i)^auto|yes|1$' { "1" } else { None }

C_RESET     := if C_ENABLED == "1" { `echo -e "\033[0m"`    } else { None }
C_BLACK     := if C_ENABLED == "1" { `echo -e "\033[0;30m"` } else { None }
C_RED       := if C_ENABLED == "1" { `echo -e "\033[0;31m"` } else { None }
C_GREEN     := if C_ENABLED == "1" { `echo -e "\033[0;32m"` } else { None }
C_YELLOW    := if C_ENABLED == "1" { `echo -e "\033[0;33m"` } else { None }
C_BLUE      := if C_ENABLED == "1" { `echo -e "\033[0;34m"` } else { None }
C_MAGENTA   := if C_ENABLED == "1" { `echo -e "\033[0;35m"` } else { None }
C_CYAN      := if C_ENABLED == "1" { `echo -e "\033[0;36m"` } else { None }
C_WHITE     := if C_ENABLED == "1" { `echo -e "\033[0;37m"` } else { None }
