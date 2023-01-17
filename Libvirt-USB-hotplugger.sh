#!/bin/bash

sScript="$( realpath -s "$0" )"
sUDevFile="/usr/lib/udev/rules.d/40-VirshHotplugUSB.rules"
sLibVirtPath="/etc/libvirt/qemu/"

# udev-rules
if [[ ! -e "$sUDevFiles" ]]; then
	cat << EOF > "$sUDevFile"
# Hotplug USB to VMs
ACTION=="add|remove", SUBSYSTEM=="usb", ENV{DEVNUM}=="[0-9]*", RUN+="/bin/bash $sScript '%E{ACTION}' '%E{BUSNUM}' '%E{DEVNUM}' '%E{ID_VENDOR_ID}' '%E{ID_MODEL_ID}' '%E{ID_REVISION}' '%E{MAJOR}'"
EOF
	udevadm control --reload-rules
fi

# Check for hexadecimal / octal / decimal number
isNumber(){
	[[ "$1" =~ ^(0x[A-Fa-f0-9]+|[0-9]+)$ ]]
}

# Remove non-existing devices
sVmXML="<d>$( xmlstarlet sel -t -m "/domain/devices/hostdev[@mode='subsystem'][@type='usb'][./source/@startupPolicy='optional']" -e u -c "/domain/name" -c "." "$sLibVirtPath"*".xml" )</d>"
for (( iHostDev = 0; ++iHostDev ; )); do
	sHostDev="$( echo "$sVmXML" | xmlstarlet sel -t -c "/d/u[$iHostDev]" )"
	[[ -n "$sHostDev" ]] || break
	
	readarray -t asDev <<< "$( echo "$sHostDev" | xmlstarlet sel -t -m "/u/hostdev/source" -c 'concat(../../name, ";", ./vendor/@id, ";", ./product/@id, ";", ./address/@bus, ";", ./address/@device)' | tr ";" $'\n' )"
	
	for i in {1..4}; do
		[[ -z "${asDev[$i]}" ]] && continue
		isNumber "${asDev[$i]}" || continue 2
		{ (( $i < 3 )) && asDev[$i]="$( printf "%04x" "$(( ${asDev[$i]} ))" )"; } || asDev[$i]="$(( ${asDev[$i]} ))"
	done
	
	sArgs=""
	[[ -z "${asDev[1]}${asDev[2]}" ]] || sArgs="-d '${asDev[1]}:${asDev[2]}' "
	[[ -z "${asDev[3]}${asDev[4]}" ]] || sArgs="$sArgs-s '${asDev[3]}:${asDev[4]}'"
	
	[[ -n "$( eval "lsusb $sArgs" )" ]] || {
		# ToDo: Filter only devices from redirfilter
	
		sTmp="$( mktemp )"
		echo "$sHostDev" | xmlstarlet sel -t -c "/u/hostdev" > "$sTmp"
		virsh detach-device "${asDev[0]}" --file "$sTmp" --persistent
		rm "$sTmp"
	}
done

# Add device based on redirfilter
if [[ "$1" = "add" ]]; then
	xmlstarlet sel -t -m $"/domain/devices/redirfilter/usbdev[@allow='yes']" -c 'concat(@vendor[.!='-1'], ";", @product[.!='-1'], ";", @class[.!='-1'], ";", @version[.!='-1'], ";", /domain/name)' -o $'\n' "$sLibVirtPath"*".xml" 2> /dev/null | while read -r sVmXML; do
		readarray -t asDev <<< "$( echo "$sVmXML" | tr ";" $'\n' )"
		
		for i in {0..3}; do
			isNumber "${asDev[$i]:-0}" || continue 2
		done
		
		[[ -n "${asDev[0]}${asDev[1]}${asDev[2]}${asDev[3]}" ]] || continue # no empty redirfilters
		[[ -z "${asDev[0]}" ]] || (( 16#"${4:-0}" == ${asDev[0]} )) || continue
		[[ -z "${asDev[1]}" ]] || (( 16#"${5:-0}" == ${asDev[1]} )) || continue
		[[ -z "${asDev[2]}" ]] || (( 10#"${7:-0}" == ${asDev[2]} )) || continue
		[[ -z "${asDev[3]}" ]] || [[ "${asDev[3]}" = "$6" ]] || continue
		

# All not working:
#		virt-xml "${asDev[4]}" --update --add-device  --hostdev "address.type=usb,address.bus=0x$( printf "%02x" $(( 10#$2 )) ),address.devno=0x$( printf "%02x" $(( 10#$3 )) )"
#		virt-xml "${asDev[4]}" --update --add-device --hostdev "$2.$3" > not working if many devices are being added: Did not find a matching node device for '001.046'	
#		virt-xml "${asDev[4]}" --update --add-device --hostdev "$(  printf "%03o.%03o" $(( 10#$2 )) $(( 10#$3 )) )" #> not working if many devices are being added: Did not find a matching node device for '001.071'	
		
		sTmp="$( mktemp )"
		cat <<- EOF > "$sTmp"
			<hostdev mode="subsystem" type="usb">
			  <source startupPolicy="optional">
			    <vendor id="0x$4"/>
			    <product id="0x$5"/>
			    <address type="usb" bus="$(( 10#$2 ))" device="$(( 10#$3 ))"/>
			  </source>
			</hostdev>
		EOF
	
		virsh attach-device "${asDev[4]}" --file "$sTmp" --persistent
		rm "$sTmp"
		break
	done
elif [[ "$1" = "remove" ]]; then
	exit # Should already have been done by tidying up of non-existent devices
fi
