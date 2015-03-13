# -*- encoding: utf-8 -*-
require_relative './util'

# Add the `task_name` column as a mandatory link between `repo` and a task.
# After this, the existing link from `policy` to a task is no longer required,
# but still serves as an override on the policy level.
Sequel.migration do
  up do
    extension(:constraint_validations)

    add_column :repos, :task_name, String, :null => true

    from(:repos).update(:task_name => 'noop')

    alter_table(:repos) { set_column_not_null :task_name }

    alter_table(:policies) { set_column_allow_null :task_name }

    # ASM specific: all repos with policies using tasks starting with windows2012
    # or windows2008 should be migrated to windows2012 or windows2012 tasks.
    %w(windows2008 windows2012).each do |task_name|
      from(:policies)
          .join(:repos, :id => :repo_id)
          .select_group(:repos__name)
          .grep(:policies__task_name, "#{task_name}%")
          .each do |repo|
        puts "Setting repo #{repo[:name]} to task #{task_name}"
        from(:repos).where(name: repo[:name]).update(:task_name => task_name)
      end
    end

    # ASM specific: migrate repos with policies using tasks we support
    %w(vmware_esxi redhat redhat7).each do |task_name|
      from(:policies)
          .join(:repos, :id => :repo_id)
          .select_group(:repos__name)
          .where(:policies__task_name => task_name)
          .each do |repo|
        puts "Setting repo #{repo[:name]} to task #{task_name}"
        from(:repos).where(name: repo[:name]).update(:task_name => task_name)
      end
    end

    #ASM specific.  Ensure our default esxi repos map to the vmware_esxi task.
    %w(esxi-5.1 esxi-5.5).each do |repo_name|
      from(:repos).where(:name => repo_name).update(:task_name => 'vmware_esxi')
    end

    # Warn about repos left with "noop" task
    from(:repos).where(:task_name => 'noop').each do |repo|
      puts _("Warning: no task could be determined for repo #{repo[:name]}")
    end

  end

  down do
    # Move back to policy if policy is empty.
    from(:policies).exclude(:task_name => nil).each do |policy|
      puts "Policy #{policy[:name]} already has a task_name; not overriding"
    end
    from(:repos).each do |repo_iterator|
      from(:policies).
          where(repo_id: repo_iterator[:id], task_name: nil).
          update(:task_name => repo_iterator[:task_name])
    end
    alter_table(:repos) { drop_column :task_name }
    alter_table(:policies) { set_column_not_null :task_name }
  end
end
