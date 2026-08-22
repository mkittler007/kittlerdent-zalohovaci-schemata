#!/bin/sh 

BASEDIR=/volume1/RTG_OPG/Sync/VXIMAGES/
ARCHIVEDIR=/volume1/RTG_OLD/Sync/VXIMAGES/

mkdir -p "$ARCHIVEDIR"

cd "$BASEDIR" && find . -type f \( -name "*.TIF" -o -name "*.tif" -o -name "*.JPG" -o -name "*.jpg" -o -name "*.jif" \) -mtime +1059 -print | 
	while read line ; do
		TARGET="$ARCHIVEDIR/`dirname $line`"
		
		echo "Moving $BASEDIR/$line to $TARGET"

		mkdir -p $TARGET
		mv -n $line $TARGET
	done

