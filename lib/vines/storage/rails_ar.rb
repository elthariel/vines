# encoding: UTF-8

require 'yaml'

module Vines
  class Storage
    class RailsAr < Storage
      register :rails_ar

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

      # We are using rails configuration
      %w[user_model user_name user_password].each do |name|
        define_method(name) do |*args|
          if args.first
            @config[name.to_sym] = args.first
          else
            @config[name.to_sym]
          end
        end
      end

      def initialize(&block)
        @config = {}
        instance_eval(&block)
      end

      def find_user(jid)
        jid = JID.new(jid).bare.to_s
        return if jid.empty?
        xuser = user_by_jid(jid)
        return Vines::User.new(jid: jid).tap do |user|
          user.name, user.password = xuser.send(@config[:user_name]), xuser.send(@config[:user_password])
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
        # User management is to be managed via the rails application.
        xuser = user_by_jid(user.jid) #|| User.new(jid: user.jid.bare.to_s)
        # xuser.name = user.name
        # xuser.password = user.password

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

      private
      ## We are using rails connection
      # def establish_connection
      #   ActiveRecord::Base.logger = Logger.new('log/vines-db.log')
      #   ActiveRecord::Base.establish_connection(@config)
      # end

      def user_by_jid(jid)
        jid = JID.new(jid).bare.to_s
        @config[:user_model].find_by_jid(jid, :include => {:contacts => :groups})
      end

      def fragment_by_jid(jid, node)
        jid = JID.new(jid).bare.to_s
        clause = 'user_id=(select id from users where jid=?) and root=? and namespace=?'
        Fragment.where(clause, jid, node.name, node.namespace.href).first
      end

      def groups(contact)
        contact.groups.map {|name| @config[:user_model].find_or_create_by_name(name.strip) }
      end
    end
  end
end
