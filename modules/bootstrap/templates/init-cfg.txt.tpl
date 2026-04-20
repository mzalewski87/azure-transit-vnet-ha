type=dhcp-client
ip-address=
netmask=
default-gateway=
hostname=${hostname}
%{~ if panorama_vm_auth_key != "" ~}
vm-auth-key=${panorama_vm_auth_key}
%{~ endif ~}
panorama-server=${panorama_server}
panorama-server-2=
tplname=${panorama_template_stack}
dgname=${panorama_device_group}
%{~ if authcodes != "" ~}
authcodes=${authcodes}
%{~ endif ~}
dns-primary=168.63.129.16
dns-secondary=8.8.8.8
ntp-server-1=0.europe.pool.ntp.org
ntp-server-2=1.europe.pool.ntp.org
timezone=Europe/Warsaw
dhcp-send-hostname=yes
dhcp-send-client-id=yes
dhcp-accept-server-hostname=yes
dhcp-accept-server-domain=yes
