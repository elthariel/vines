# encoding: UTF-8

module Vines
  class Storage
    class Sql < Storage
      register :sql

      class Contact < ActiveRecord::Base
        belongs_to :user
      end
      class Fragment < ActiveRecord::Base
        belongs_to :user
      end
      class Group < ActiveRecord::Base; end
      class User < ActiveRecord::Base
        has_many :contacts,  :dependent => :destroy
        has_many :fragments, :dependent => :delete_all
      end

      # Wrap the method with ActiveRecord connection pool logic, so we properly
      # return connections to the pool when we're finished with them. This also
      # defers the original method by pushing it onto the EM thread pool because
      # ActiveRecord uses blocking IO.
      def self.with_connection(method, args={})
        deferrable = args.key?(:defer) ? args[:defer] : true
        old = "_with_connection_#{method}"
        alias_method old, method
        define_method method do |*args|
          ActiveRecord::Base.connection_pool.with_connection do
            method(old).call(*args)
          end
        end
        defer(method) if deferrable
      end

      %w[adapter host port database username password pool model_user_name model_user_password].each do |name|
        define_method(name) do |*args|
          if args.first
            @config[name.to_sym] = args.first
          else
            @config[name.to_sym]
          end
        end
      end

      def rails_mode(active = true)
        @config[:rails_mode] = active
        if active
          rails_env = ENV['RAILS_ENV'] ? ENV['RAILS_ENV'] : 'development'
          db_config = YAML::load_file('./config/database.yml')

          if db_config.empty?
            puts "You must run Vines with 'rails_mode true' from rails root"
            exit 42
          end
          db_config = db_config[rails_env]

          @config = @config.merge! db_config
        end
      end

      def initialize(&block)
        @config = {}
        instance_eval(&block)
        unless @config[:rails_mode] # We assume rails db configuration is good
          required = [:adapter, :database]
          required << [:host, :port] unless @config[:adapter] == 'sqlite3'
          required.flatten.each {|key| raise "Must provide #{key}" unless @config[key] }
          [:username, :password].each {|key| @config.delete(key) if empty?(@config[key]) }
        end
        establish_connection
      end

      def find_user(jid)
        jid = JID.new(jid).bare.to_s
        return if jid.empty?
        xuser = user_by_jid(jid)
        return Vines::User.new(jid: jid).tap do |user|
          user.name, user.password = xuser.send(@config[:model_user_name]), xuser.send(@config[:model_user_password])
          xuser.contacts.each do |contact|
            groups = contact.groups.map {|group| group.name }
            user.roster << Vines::Contact.new(
              jid: contact.jid,
              name: contact.name,
              subscription: contact.subscription,
              ask: contact.ask,
              groups: groups)
          end
        end if xuser
      end
      with_connection :find_user

      def save_user(user)
        if @config[:rails_mode]
          # If using rails mode, we want to disable user management in Vines
          xuser = user_by_jid(user.jid)
        else
          xuser = user_by_jid(user.jid) || Sql::User.new(jid: user.jid.bare.to_s)
          xuser.name = user.name
          xuser.password = user.password
        end

        # remove deleted contacts from roster
        xuser.contacts.delete(xuser.contacts.select do |contact|
          !user.contact?(contact.jid)
        end)

        # update contacts
        xuser.contacts.each do |contact|
          fresh = user.contact(contact.jid)
          contact.update_attributes(
            name: fresh.name,
            ask: fresh.ask,
            subscription: fresh.subscription,
            groups: groups(fresh))
        end

        # add new contacts to roster
        jids = xuser.contacts.map {|c| c.jid }
        user.roster.select {|contact| !jids.include?(contact.jid.bare.to_s) }
          .each do |contact|
            xuser.contacts.build(
              user: xuser,
              jid: contact.jid.bare.to_s,
              name: contact.name,
              ask: contact.ask,
              subscription: contact.subscription,
              groups: groups(contact))
          end
        xuser.save
      end
      with_connection :save_user

      def find_vcard(jid)
        jid = JID.new(jid).bare.to_s
        return if jid.empty?
        if xuser = user_by_jid(jid)
          Nokogiri::XML(xuser.vcard).root rescue nil
        end
      end
      with_connection :find_vcard

      def save_vcard(jid, card)
        xuser = user_by_jid(jid)
        if xuser
          xuser.vcard = card.to_xml
          xuser.save
        end
      end
      with_connection :save_vcard

      def find_fragment(jid, node)
        jid = JID.new(jid).bare.to_s
        return if jid.empty?
        if fragment = fragment_by_jid(jid, node)
          Nokogiri::XML(fragment.xml).root rescue nil
        end
      end
      with_connection :find_fragment

      def save_fragment(jid, node)
        jid = JID.new(jid).bare.to_s
        fragment = fragment_by_jid(jid, node) ||
          Sql::Fragment.new(
            user: user_by_jid(jid),
            root: node.name,
            namespace: node.namespace.href)
        fragment.xml = node.to_xml
        fragment.save
      end
      with_connection :save_fragment

      # Create the tables and indexes used by this storage engine.
      def create_schema(args={})
        # If integrated into rails, we will use rails migrations
        return if @config[:rails_mode]

        args[:force] ||= false

        ActiveRecord::Schema.define do
          create_table :users, force: args[:force] do |t|
            t.string :jid,      limit: 512, null: false
            t.string :name,     limit: 256, null: true
            t.string :password, limit: 256, null: true
            t.text   :vcard,    null: true
          end
          add_index :users, :jid, unique: true

          create_table :contacts, force: args[:force] do |t|
            t.integer :user_id,      null: false
            t.string  :jid,          limit: 512, null: false
            t.string  :name,         limit: 256, null: true
            t.string  :ask,          limit: 128, null: true
            t.string  :subscription, limit: 128, null: false
          end
          add_index :contacts, [:user_id, :jid], unique: true

          create_table :groups, force: args[:force] do |t|
            t.string :name, limit: 256, null: false
          end
          add_index :groups, :name, unique: true

          create_table :contacts_groups, id: false, force: args[:force] do |t|
            t.integer :contact_id, null: false
            t.integer :group_id,   null: false
          end
          add_index :contacts_groups, [:contact_id, :group_id], unique: true

          create_table :fragments, force: args[:force] do |t|
            t.integer :user_id,   null: false
            t.string  :root,      limit: 256, null: false
            t.string  :namespace, limit: 256, null: false
            t.text    :xml,       null: false
          end
          add_index :fragments, [:user_id, :root, :namespace], unique: true
        end
      end
      with_connection :create_schema, defer: false

      private

      def establish_connection
        ActiveRecord::Base.logger = Logger.new @config[:rails_mode] ? 'log/vinesdb.log' : '/dev/null'
        ActiveRecord::Base.establish_connection(@config)
        # has_and_belongs_to_many requires a connection so configure the
        # associations here rather than in the class definitions above.
        Sql::Contact.has_and_belongs_to_many :groups
        Sql::Group.has_and_belongs_to_many :contacts
      end

      def user_by_jid(jid)
        jid = JID.new(jid).bare.to_s
        Sql::User.find_by_jid(jid, :include => {:contacts => :groups})
      end

      def fragment_by_jid(jid, node)
        jid = JID.new(jid).bare.to_s
        clause = 'user_id=(select id from users where jid=?) and root=? and namespace=?'
        Sql::Fragment.where(clause, jid, node.name, node.namespace.href).first
      end

      def groups(contact)
        contact.groups.map {|name| Sql::Group.find_or_create_by_name(name.strip) }
      end
    end
  end
end
