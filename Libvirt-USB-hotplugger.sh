#!/bin/bash

sScript="$( realpath -s "$0" )"
sUDevFile="/usr/lib/udev/rules.d/99-VirshHotplugUSB.rules"

# udev-rules
if [[ ! -e "$sUDevFile" ]]; then
	cat << EOF > "$sUDevFile"
# Hotplug USB to VMs
ACTION=="add|remove", SUBSYSTEM=="usb", ENV{DEVNUM}=="[0-9]*", RUN+="/bin/bash $sScript"
EOF
	udevadm control --reload-rules
	
	sudo crontab <<< "$( sudo crontab -l 2> /dev/null | { sed -e "/\/bin\/bash $( echo "$sScript" | sed -e 's/[]\/$*.^[]/\\&/g' )/d"; echo "@reboot		/bin/bash $sScript"; } )"
fi

# Check for hexadecimal / octal / decimal number
isNumber(){
	[[ "$1" =~ ^(0x[A-Fa-f0-9]+|[0-9]+)$ ]]
}

# Extract relevant XML
sVmXML="<d>"
sRedir=""
while read -r sDomain; do
	# Extract attached devices, having the expected appearance as attached with snippet below (including startupPolicy=optional, vendor/@id, product/@id, address/type=usb, address/@bus and address/@device).
	sVmXML="$sVmXML$(
		virsh dumpxml "$sDomain" 2> /dev/null | xmlstarlet sel -t -m "/domain/devices/hostdev[@mode='subsystem'][@type='usb'][./source[@startupPolicy='optional'][./vendor/@id][./product/@id][./address[@bus][@device]]]" -e u -c "/domain/name" -c "." 2> /dev/null
	)"
	sRedir="$sRedir$(
		virsh dumpxml "$sDomain" 2> /dev/null | xmlstarlet sel -t -m $"/domain/devices/redirfilter/usbdev[@allow='yes']" -c 'concat(@vendor[.!='-1'], ";", @product[.!='-1'], ";", @class[.!='-1'], ";", @version[.!='-1'], ";", /domain/name)' -o $'\n' 2> /dev/null
	)"
done <<< "$( virsh list --name --all )"
sVmXML="$sVmXML</d>"

# Add device based on redirfilter
lsusb | sed 's/[^0-9]\+\([0-9]\+\)[^0-9]\+\([0-9]\+\).\+ \([[:alnum:]]\+:[[:alnum:]]\+\) .*/\1:\2:\3/g' | while read -r sUSB; do
	readarray -t asUSB <<< "$( echo "${sUSB,,}" | tr ":" $'\n' )"
	
	sUSB="$( lsusb -v -d "${asUSB[2]}:${asUSB[3]}" -s "${asUSB[0]}:${asUSB[1]}" 2> /dev/null )"
	asUSB[4]="$( echo "$sUSB" | grep "\sbcdDevice\s" | sed 's/\s\+\w\+\s\+\(\S\+\)\s*/\1/g' )"
	asUSB[5]="$( echo "$sUSB" | grep "\sbDeviceClass\s" | sed 's/\s\+\w\+\s\+\([[:digit:]]\+\)\s\+.*/\1/g' )"

	while read -r sDir; do
		readarray -t asDev <<< "$( echo "$sDir" | tr ";" $'\n' )"
		
		for i in {0..3}; do
			isNumber "${asDev[$i]:-0}" || continue 2
		done
		
		[[ -n "${asDev[0]}${asDev[1]}${asDev[2]}${asDev[3]}" ]] || continue # no empty redirfilters
		[[ -z "${asDev[0]}" ]] || (( 16#"${asUSB[2]}" == ${asDev[0]} )) || continue
		[[ -z "${asDev[1]}" ]] || (( 16#"${asUSB[3]}" == ${asDev[1]} )) || continue
		[[ -z "${asDev[2]}" ]] || (( 10#"${asUSB[4]}" == ${asDev[2]} )) || continue
		[[ -z "${asDev[3]}" ]] || [[ "${asDev[3]}" = "$6" ]] || continue		

# All not working:
#		virt-xml "${asDev[4]}" --update --add-device  --hostdev "address.type=usb,address.bus=0x$( printf "%02x" $(( 10#$2 )) ),address.devno=0x$( printf "%02x" $(( 10#$3 )) )"
#		virt-xml "${asDev[4]}" --update --add-device --hostdev "$2.$3" > not working if many devices are being added: Did not find a matching node device for '001.046'	
#		virt-xml "${asDev[4]}" --update --add-device --hostdev "$(  printf "%03o.%03o" $(( 10#$2 )) $(( 10#$3 )) )" #> not working if many devices are being added: Did not find a matching node device for '001.071'	
		
		if [[ -z "$( echo "${sVmXML,,}" | xmlstarlet sel -t -c "/d/u/hostdev/source[./vendor/@id='0x${asUSB[2]}'][./product/@id='0x${asUSB[3]}'][./address[@bus='$(( 10#${asUSB[0]} ))'][@device='$(( 10#${asUSB[1]} ))']]" )" ]]; then
			# Add device to VM
			cat <<- EOF | virsh attach-device "${asDev[4]}" --file /dev/stdin --persistent 
				<hostdev mode="subsystem" type="usb">
				  <source startupPolicy="optional">
					<vendor id="0x${asUSB[2]}"/>
					<product id="0x${asUSB[3]}"/>
					<address type="usb" bus="$(( 10#${asUSB[0]} ))" device="$(( 10#${asUSB[1]} ))"/>
				  </source>
				</hostdev>
			EOF
		else
			# Delete device from list of connected devices
			sVmXML="$( echo "$sVmXML" | xmlstarlet ed -d "/d/u[./hostdev/source/address[@bus='$(( 10#${asUSB[0]} ))'][@device='$(( 10#${asUSB[1]} ))']]" )"
		fi
		
		continue 2
	done <<< "$sRedir"
done

# Remove non-existing devices
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
	
		echo "$sHostDev" | xmlstarlet sel -t -c "/u/hostdev" | virsh detach-device "${asDev[0]}" --file /dev/stdin --persistent
	}
done
