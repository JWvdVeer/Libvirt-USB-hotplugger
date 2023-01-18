# Libvirt-USB-hotplugger
Hotplug USB-devices using virsh-tool in libvirt, based on redirfilter-tag.

Use:
- In your libvirt-VM add redirfilter with settings fitting your use case, for example (Sonoff Zigbee device):
```xml
    <redirfilter>
      <usbdev vendor='0x10C4' product='0xEA60' allow='yes'/>
      <usbdev allow='yes'/>
      <!-- depending on your use case and whether you want to be able to add other devices yes/no; however virt-manager isn't dealing all too well with it -->
    </redirfilter>
```

- Install xmlstarlet ( sudo apt xmlstarlet ), for the Xpath-support.
- Put the Libvirt-USB-hotplugger.sh script somewhere and run it once, in order to generate the udev-rules.
- All redirfilter usbdev's will be auto-hotplugged as soon as inserted or deleted.
- Feel free to improve / adapt. In order to make this more convenient, I already added some remarks.
- Make sure the 'hub' in the VM has enough ports (throw away some spicevm-ports if not used). As far as I know, up to four devices are supported. Otherwise you'll need a real hub.
