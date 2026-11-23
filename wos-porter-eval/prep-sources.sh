#!/bin/bash
# Prepare one git repo per Tier 1/2 package for WoS Porter: the source tree the
# MSYS2 recipe builds (upstream tarball/git + MSYS2 patches, after prepare()),
# extracted under /c/wos-eval/prep so the recipe directories stay untouched.
R=/home/HCKTest/MSYS2-packages
P=/c/wos-eval/prep; W=/c/wos-eval/work
mkdir -p $P $W
LOG=/c/wos-eval/prep.log; : > $LOG
for p in "$@"; do
  echo "=== $p" | tee -a $LOG
  rm -rf "$P/$p" "$W/$p"
  if [ "$p" = filesystem ]; then
    mkdir -p "$W/$p" && (cd $R/$p && git ls-files . | xargs -I{} cp --parents {} "$W/$p/")
  else
    ( cd $R/$p && BUILDDIR=$P SRCDEST=$R/$p makepkg --nobuild --nodeps --skippgpcheck --noconfirm >>$LOG 2>&1 ) || { echo "  makepkg failed" | tee -a $LOG; continue; }
    src=$(ls -d $P/$p/src/*/ 2>/dev/null | grep -v -e '/build' -e '/dest' -e 'unzip-fedora' | head -1)
    [ -z "$src" ] && { echo "  no source dir" | tee -a $LOG; continue; }
    cp -a "$src" "$W/$p"
  fi
  ( cd "$W/$p" && rm -rf .git && git init -q -b main && git add -A -f . >/dev/null 2>&1 &&
    git -c user.name=aswin-mcw -c user.email=aswin.kalies@multicorewareinc.com commit -q -m "Import $p source as built by the MSYS2 recipe (upstream + MSYS2 patches)" ) &&
    echo "  ok $(cd $W/$p && git ls-files | wc -l) files" | tee -a $LOG
done
