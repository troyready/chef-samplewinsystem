#
# Cookbook Name:: samplewinsystem
# Recipe:: default
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

hosts_file = 'c:/windows/system32/drivers/etc/hosts'
ruby_block 'setup_dns' do
  block do
    open(hosts_file, 'ab') do |f|
      f.puts "192.168.33.33 dc.mysubdomain.myorg.com\r\n"
      f.puts "192.168.33.33 mysubdomain.myorg.com\r\n"
      f.puts "192.168.33.33 MYORG\r\n"
    end
  end
  not_if { File.readlines(hosts_file).grep(/MYORG/).size > 0 }
end

dns_cmd = Mixlib::ShellOut.new(
  'netsh interface ipv4 show dnsserver "Ethernet 2"'
)
dns_cmd.run_command
execute 'add_dc_dns' do
  command 'netsh interface ipv4 add dnsserver "Ethernet 2" '\
          'address=192.168.33.33 index=1'
  not_if { dns_cmd.stdout.include?('192.168.33.33') }
end

joined_cmd = Mixlib::ShellOut.new('wmic computersystem get domain')
joined_cmd.run_command
unless joined_cmd.stdout =~ /myorg/i
  powershell_script 'join_domain' do
    code <<-EOH
    $domain = "MYORG"
    $password = "Secretpassword123" | ConvertTo-SecureString -asPlainText -Force
    $username = "$domain\\Administrator"
    $credential = New-Object System.Management.Automation.PSCredential($username,$password)
    Add-Computer -DomainName $domain -Credential $credential -Force
    EOH
  end
  reboot 'post_domain_join_reboot' do
    action :reboot_now
    reason 'Need to reboot to complete domain joining'
  end
end

pkcs12_file = 'C:/Users/vagrant/AppData/Local/Temp/kitchen/cache/'\
              'star.mysubdomain.myorg.com.pfx'
pkcs12_pass = 'secretpassword'
ssl_keypair = data_bag_item('vault', 'star_mysubdomain_myorg_com_keypair')
ruby_block 'deploy_winrm_cert' do
  block do
    require 'openssl'
    ssl_key = OpenSSL::PKey.read ssl_keypair['key']
    ssl_cert = OpenSSL::X509::Certificate.new ssl_keypair['cert']
    pkcs12_cert_name = nil
    ca_certs = []
    ssl_keypair['ca'].each do |new_ca|
      ca_certs << OpenSSL::X509::Certificate.new(new_ca)
    end

    pkcs12 = OpenSSL::PKCS12.create(
      pkcs12_pass,
      pkcs12_cert_name,
      ssl_key,
      ssl_cert,
      ca_certs
    )
    File.open(pkcs12_file, 'wb') { |f| f << pkcs12.to_der }
  end
  not_if { File.exist?(pkcs12_file) }
end

fw_cmd = Mixlib::ShellOut.new(
  'netsh advfirewall firewall show rule name="winrm-ssl"'
)
fw_cmd.run_command
execute 'add_winrm_firewall_hole' do
  command 'netsh advfirewall firewall add rule name="winrm-ssl" '\
          'dir=in action=allow protocol=TCP localport=5986'
  not_if { fw_cmd.stdout.include?('5986') }
end

chk_winrm = Mixlib::ShellOut.new(
  'winrm e winrm/config/listener'
)
chk_winrm.run_command
unless chk_winrm.stdout.include?('5986')
  batch 'setup ssl winrm' do
    code <<-EOH
      certutil -f -p "secretpassword" -importpfx #{pkcs12_file.tr('/', '\\')}
      winrm set winrm/config/winrs @{MaxMemoryPerShellMB="300"}
      EOH
  end

  # Split this into another batch file because it didn't seem to be working
  # when it was run as a single file
  execute 'continue winrm setup' do
    command 'winrm set winrm/config @{MaxTimeoutms="1800000"}'
  end

  execute 'create winrm listener' do
    command 'winrm create winrm/config/listener?Address=*+Transport=HTTPS '\
            '@{Hostname="*.mysubdomain.myorg.com";CertificateThumbprint='\
            '"c0 ee 4c 0d 13 d6 ba 6d 97 97 19 0a 60 38 ae 90 76 6c c7 8e"}'
  end
end
