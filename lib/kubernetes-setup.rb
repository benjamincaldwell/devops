# Add current directory to load path
$LOAD_PATH.unshift File.dirname(__FILE__)

require 'helpers/printer'
require 'helpers/ansible'
require 'helpers/tasks'
require 'helpers/server'

require 'yaml'
require 'parallel'
require 'fileutils'
require 'optparse'
require 'byebug'

module Kubernetes
  class Setup
    PROJECT_DIR = File.expand_path(File.join(File.dirname(__FILE__), '..'))

    def initialize
      @options = {}
      @options[:config_dir] = File.join(PROJECT_DIR, "config")

      playbook_dir = File.join(PROJECT_DIR, 'ansible/playbooks')
      role_dir = File.join(PROJECT_DIR, 'ansible/roles')

      @options[:config_file] = File.join(@options[:config_dir], 'kubernetes-setup.yml')

      @options[:master_hostname] = "kube-master"
      @options[:node_hostname] = "kube-node-{{number}}"
      @options[:node_hostname_regex] = /^node-(\d*)$/

      @ansible = Ansible.new(playbook_dir: playbook_dir, role_dir: role_dir, default_host: "kubernetes")

      OptionParser.new do |opts|
        opts.banner = "Usage: kubernetes-setup [options]"

        opts.on('-c', '--config NAME', 'config file') { |v| @options[:config_file] = File.expand_path(v) }
      end.parse!
    end

    def run
      FileUtils.mkdir_p(@options[:config_dir]) unless File.exist?(@options[:config_dir])

      read_and_filter

      nodes = @nodes
      master = @master
      workers = @workers

      ansible = @ansible

      options = @options

      cluster_config_file = File.join(@options[:config_dir], "cluster.conf")

      Tasks.new_task "Master node" do
        list { [master] }
        list_logger { |node| logger.log(node["ip"]) }
      end

      Tasks.new_task "Nodes" do
        list { workers }
        list_logger { |node| logger.log(node["ip"]) }
      end

      Tasks.new_task "Pinging Nodes" do
        list do
          Parallel.map(nodes) do |node|
            node['alive'] = if Server.ping(node)
              true
            else
              false
            end
            node
          end
        end

        list_logger do |node|
          if node['alive'] == true
            logger.puts_coloured("{{green:┃ ✓}} #{node['ip']}   role: #{node['role']}")
          else
            logger.puts_coloured("{{red:┃ ✗}} #{node['ip']}   role: #{node['role']}")
            false
          end
        end
      end

      Tasks.new_task "Changing hostnames", list_title: "Nodes to change hostnae on" do
        check? do
          hostname_nodes = Parallel.map(nodes) do |node|
            node["current_hostname"] = Server.hostname(node)
            node
          end
          # hash of taken hostname number. Initialize with true to disable 0
          # initialize with all nil so there is atleast space for each node
          hostname_db = [true, *[nil] * hostname_nodes.size]
          hostname_nodes = Parallel.map(hostname_nodes) do |node|
            if node["role"] == "master"
              node["hostname"] = options[:master_hostname]
              next node
            end

            num = node["current_hostname"][options[:node_hostname_regex], 1]

            if num
              hostname_db[num.to_i] = true
              node["hostname"] = node["current_hostname"]
            end
            node
          end
          hostname_nodes = hostname_nodes.map do |node|
            next node if node["hostname"]
            number = hostname_db.index(nil)
            node["hostname"] = options[:node_hostname].sub("{{number}}", number.to_s)
            hostname_db[number] = true
            node
          end

          @list = hostname_nodes.select { |c| c["hostname"] != c["current_hostname"] }
          @list.empty?
        end
        exec do
          Parallel.each(@list) do |node|
            Server.change_hostname(node, node["hostname"], node["current_hostname"])
          end
        end
        list_logger do |node|
          logger.log("#{node['ip']}    #{node['current_hostname']} -> #{node['hostname']}")
        end
      end

      Tasks.new_task "Upgrade ubuntu 14 to 16", list_title: "Nodes to be upgraded from ubuntu 14 to 16" do
        check? do
          @list = parallel_list nodes do |node|
            output = Server.remote_command(node, "lsb_release -a")
            version = output[/Release:\s(.*)/, 1].strip
            Gem::Version.new(version) < Gem::Version.new('16')
          end
          @list.empty?
        end
        exec do
          ansible.run_playbook(@list, '16upgrade')
        end
        list_logger do |node|
          logger.log(node['ip'])
        end
      end

      Tasks.new_task "Install python", list_title: "Nodes to install python on" do
        check? do
          @list = parallel_list nodes do |node|
            !Server.remote_check(node, "which python")
          end
          @list.empty?
        end
        exec do
          ansible.run_playbook(@list, 'ansible-bootstrap-ubuntu-16.04')
        end
        list_logger do |node|
          logger.log(node['ip'])
        end
      end

      Tasks.new_task "Bootstrapping base kubernetes on master and nodes", list_title: "Nodes to bootstrap" do
        check? do
          @list = parallel_list nodes do |node|
            !Server.remote_check(node, "which kubeadm && which kubelet && which kubectl")
          end
          @list.empty?
        end
        exec do
          ansible.run_playbook(nodes, 'kubernetes/bootstrap')
        end
        list_logger do |node|
          logger.log(node['ip'])
        end
      end

      Tasks.new_task "Bootstrapping master", list_title: "Master to bootstrap" do
        check? do
          @list = parallel_list [master] do |node|
            !Server.remote_check(node, "kubectl cluster-info")
          end
          @list.empty?
        end
        exec do
          ansible.run_playbook([master], 'kubernetes/master-init')
        end
        list_logger do |node|
          logger.log(node['ip'])
        end
      end

      Tasks.new_task "Joining nodes to cluster", list_title: "Nodes to join" do
        check? do
          @list = parallel_list workers do |node|
            !Server.remote_check(node, "kubectl --kubeconfig  /etc/kubernetes/kubelet.conf get nodes | grep $(hostname)")
          end
          @list.empty?
        end
        exec do
          command = 'kubectl -n kube-system get secret clusterinfo -o yaml | grep token-map | awk \'{print $2}\' | base64 -d | sed "s|{||g;s|}||g;s|:|.|g;s/\"//g;" | xargs echo'
          join_token = Server.remote_command(master, command)
          ansible.run_playbook(@list, 'kubernetes/node-join', join_token: join_token, master_ip: master["ip"])
        end
        list_logger do |node|
          logger.log(node['ip'])
        end
      end

      Tasks.new_task "Copying over cluster configuration file" do
        check? { File.exist?(cluster_config_file) }
        exec do
          logger.puts_blue("Downloading kubeconfig to #{cluster_config_file}")
          Server.download!(master, "/etc/kubernetes/admin.conf", cluster_config_file)
        end
      end

      Tasks.run
    end

    private

    def read_and_filter
      config = YAML.load_file(@options[:config_file])

      @nodes = config.select { |node| node["remove"] != true }

      @master = {}
      @workers = []

      @nodes.each do |node|
        case node['role']
        when 'node'
          @workers << node
        when nil
          node["role"] = "node"
          @workers << node
        when 'master'
          next @master = node if @master.empty?
          raise 'only 1 master node is supported'
        else
          raise "invalid node type: #{node.inspect}"
        end
      end

      raise 'no master node' if @master.empty?
    end

    def check_hostname(node)
      puts node["hostname"]
    end
  end
end

def parallel_list(nodes)
  list = Parallel.map(nodes) do |node|
    yield node
  end

  nodes.select.with_index { |_, i| list[i] }
end

Kubernetes::Setup.new.run if __FILE__ == $PROGRAM_NAME
