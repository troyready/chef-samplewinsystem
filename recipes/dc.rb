#
# Cookbook Name:: samplewinsystem
# Recipe:: dc
#
# Copyright 2015 Troy Ready
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

file '/etc/hosts' do
  content "127.0.0.1       localhost\n"\
          "192.168.33.33 dc.mysubdomain.myorg.com dc\n"\
          "\n"\
          "# The following lines are desirable for IPv6 capable hosts\n"\
          "::1     localhost ip6-localhost ip6-loopback\n"\
          "ff02::1 ip6-allnodes\n"\
          "ff02::2 ip6-allrouters\n"
  mode '0644'
end

package 'samba'
service 'smbd' do
  action [:stop]
end

# FIXME: need a better check for the domain having already been provisioned
unless File.exist?('/var/lib/samba/private/krb5.conf')
  execute 'rm /etc/samba/smb.conf'
  execute 'provision_domain' do
    command 'samba-tool domain provision --use-rfc2307 '\
            '--option="interfaces=lo eth1" '\
            '--option="bind interfaces only=yes" '\
            '--realm=MYSUBDOMAIN.MYORG.COM '\
            '--domain=MYORG '\
            '--site=kitchen '\
            '--adminpass=Secretpassword123 '\
            '--function-level=2008_R2'
    notifies :restart, 'service[samba-ad-dc]'
  end
end

replace_or_add 'add_nameservers' do
  path '/etc/network/interfaces'
  pattern '      dns-nameservers.*'
  line '      dns-nameservers 192.168.33.33 10.0.2.3'
end
replace_or_add 'add_dns_search' do
  path '/etc/network/interfaces'
  pattern '      dns-search.*'
  line '      dns-search mysubdomain.myorg.com myorg.com'
  notifies :restart, 'service[networking]', :immediately
end

service 'networking' do
  action :nothing
end

service 'samba-ad-dc' do
  action [:enable, :start]
end
