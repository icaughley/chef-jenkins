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
#

pkey = "#{node[:jenkins][:server][:home]}/.ssh/id_rsa"

user node[:jenkins][:server][:user] do
  home node[:jenkins][:server][:home]
end

directory node[:jenkins][:server][:home] do
  recursive true
  owner node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
end

directory "#{node[:jenkins][:server][:home]}/.ssh" do
  mode 0700
  owner node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
end

execute "ssh-keygen -f #{pkey} -N ''" do
  user  node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
  not_if { File.exists?(pkey) }
end

ruby_block "store jenkins ssh pubkey" do
  block do
    node.set[:jenkins][:server][:pubkey] = File.open("#{pkey}.pub") { |f| f.gets }
  end
end

case node.platform
when "ubuntu", "debian"
  include_recipe "apt"
  include_recipe "java"

  pid_file = "/var/run/jenkins/jenkins.pid"
  install_starts_service = true

  apt_repository "jenkins" do
    uri "#{node.jenkins.package_url}/debian"
    components %w[binary/]
    key "http://pkg.jenkins-ci.org/debian/jenkins-ci.org.key"
    action :add
  end
when "centos", "redhat"
  include_recipe "yum"

  pid_file = "/var/run/jenkins.pid"
  install_starts_service = false

  yum_key "jenkins" do
    url "#{node.jenkins.package_url}/redhat/jenkins-ci.org.key"
    action :add
  end

  yum_repository "jenkins" do
    description "repository for jenkins"
    url "#{node.jenkins.package_url}/redhat/"
    key "jenkins"
    action :add
  end
end

#"jenkins stop" may (likely) exit before the process is actually dead
#so we sleep until nothing is listening on jenkins.server.port (according to netstat)
ruby_block "netstat" do
  block do
    10.times do
      if IO.popen("netstat -lnt").entries.select { |entry|
          entry.split[3] =~ /:#{node[:jenkins][:server][:port]}$/
        }.size == 0
        break
      end
      Chef::Log.debug("service[jenkins] still listening (port #{node[:jenkins][:server][:port]})")
      sleep 1
    end
  end
  action :nothing
end

service "jenkins" do
  supports [ :stop, :start, :restart, :status ]
  status_command "test -f #{pid_file} && kill -0 `cat #{pid_file}`"
  action :nothing
end

ruby_block "block_until_operational" do
  block do
    until IO.popen("netstat -lnt").entries.select { |entry|
        entry.split[3] =~ /:#{node[:jenkins][:server][:port]}$/
      }.size == 1
      Chef::Log.debug "service[jenkins] not listening on port #{node.jenkins.server.port}"
      sleep 1
    end

    loop do
      url = URI.parse("#{node.jenkins.server.url}/job/test/config.xml")
      res = Chef::REST::RESTRequest.new(:GET, url, nil).call
      break if res.kind_of?(Net::HTTPSuccess) or res.kind_of?(Net::HTTPNotFound)
      Chef::Log.debug "service[jenkins] not responding OK to GET / #{res.inspect}"
      sleep 1
    end
  end
  action :nothing
end

log "jenkins: install and start" do
  notifies :install, "package[jenkins]", :immediately
  notifies :start, "service[jenkins]", :immediately unless install_starts_service
  notifies :create, "ruby_block[block_until_operational]", :immediately
  not_if do
    File.exists? "/usr/share/jenkins/jenkins.war"
  end
end

template "/etc/default/jenkins"

package "jenkins" do
  action :nothing
  notifies :create, "template[/etc/default/jenkins]", :immediately
end
