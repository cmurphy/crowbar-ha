#
# Author:: Vincent Untz
# Cookbook Name:: pacemaker
# Recipe:: stonith
#
# Copyright 2014, SUSE
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

# FIXME: delete old resources when switching mode (or agent!)

case node[:pacemaker][:stonith][:mode]
when "disabled"
when "manual"
  # nothing!

when "sbd"
  include_recipe "pacemaker::sbd"

  pacemaker_primitive "stonith-sbd" do
    agent node[:pacemaker][:stonith][:sbd][:agent]
    action [:create, :start]
  end

when "shared"
  agent = node[:pacemaker][:stonith][:shared][:agent]
  params = node[:pacemaker][:stonith][:shared][:params]

  # This needs to be done in the second phase of chef, because we need
  # cluster-glue to be installed first; hence ruby_block
  ruby_block "Check if STONITH fencing agent #{agent} is available" do
    block do
      PacemakerStonithHelper.assert_stonith_agent_valid agent
    end
  end

  if params.respond_to?("to_hash")
    primitive_params = params.to_hash
  elsif params.is_a?(String)
    primitive_params = ::Pacemaker::Resource.extract_hash(" params #{params}", "params")
  else
    message = "Unknown format for shared fencing agent parameters: #{params.inspect}."
    Chef::Log.fatal(message)
    raise message
  end

  unless primitive_params.key?("hostlist")
    message = "Missing hostlist parameter for shared fencing agent!"
    Chef::Log.fatal(message)
    raise message
  end

  pacemaker_primitive "stonith-shared" do
    agent "stonith:#{agent}"
    op node[:pacemaker][:stonith][:shared][:op]
    params primitive_params
    action [:create, :start]
  end

when "per_node"
  agent = node[:pacemaker][:stonith][:per_node][:agent]

  # This needs to be done in the second phase of chef, because we need
  # cluster-glue to be installed first; hence ruby_block
  ruby_block "Check if STONITH fencing agent #{agent} is available" do
    block do
      PacemakerStonithHelper.assert_stonith_agent_valid agent
    end
  end

  node[:pacemaker][:stonith][:per_node][:nodes].keys.each do |node_name|
    if node[:pacemaker][:stonith][:per_node][:mode] == "self"
      next unless node_name == node[:hostname]
    elsif node[:pacemaker][:stonith][:per_node][:mode] == "list"
      next unless node[:pacemaker][:stonith][:per_node][:list].include? node_name
    end

    stonith_resource = "stonith-#{node_name}"
    params = node[:pacemaker][:stonith][:per_node][:nodes][node_name][:params]

    if params.respond_to?("to_hash")
      primitive_params = params.to_hash
    elsif params.is_a?(String)
      primitive_params = ::Pacemaker::Resource.extract_hash(" params #{params}", "params")
    else
      message = "Unknown format for per-node fencing agent parameters of #{node_name}: #{params.inspect}."
      Chef::Log.fatal(message)
      raise message
    end

    # Only set one of hostname / hostlist param if none of them are present; we
    # do not overwrite it as the user might have passed more information than
    # just the hostname (some agents accept hostname:data in hostlist)
    unless primitive_params.key?("hostname") || primitive_params.key?("hostlist")
      primitive_params["hostname"] = node_name
    end

    transaction_objects = []

    pacemaker_primitive stonith_resource do
      agent "stonith:#{agent}"
      params primitive_params
      op node[:pacemaker][:stonith][:per_node][:op]
      action :update
    end
    transaction_objects << "pacemaker_primitive[#{stonith_resource}]"

    location_constraint = "l-#{stonith_resource}"
    pacemaker_location location_constraint do
      rsc stonith_resource
      score "-inf"
      lnode node_name
      action :update
    end
    transaction_objects << "pacemaker_location[#{location_constraint}]"

    pacemaker_transaction "stonith for #{node_name}" do
      cib_objects transaction_objects
      # note that this will also automatically start the resources
      action :commit_new
    end
  end

else
  message = "Unknown STONITH mode: #{node[:pacemaker][:stonith][:mode]}."
  Chef::Log.fatal(message)
  raise message
end

file "delete crowbar-watchdog.conf if not using sbd" do
  path "/etc/modules-load.d/crowbar-watchdog.conf"
  action :delete
  only_if { node[:pacemaker][:stonith][:mode] != "sbd" }
end
