module Ruboto
  module Util
    module Build
      include Verify
      ###########################################################################
      #
      # Build Subclass or Interface:
      #

      #
      # build_file: Reads the src from the appropriate location,
      #   uses the substitutions hash to modify the contents,
      #   and writes to the new location
      #
      def build_file(src, package, name, substitutions, dest='.')
        to = File.join(dest, "src/#{package.gsub('.', '/')}")
        Dir.mkdir(to) unless File.directory?(to)

        text = File.read(File.expand_path(Ruboto::GEM_ROOT + "/assets/src/#{src}.java"))
        substitutions.each {|k,v| text.gsub!(k, v)}

        File.open(File.join(to, "#{name}.java"), 'w') {|f| f << text}
      end

      #
      # get_class_or_interface: Opens the xml file and locates the specified class.
      #   Aborts if the class is not found or if it is not available for
      #   all api levels
      #
      def get_class_or_interface(klass, force=false)
        element = verify_api.find_class_or_interface(klass, "either")

        abort "ERROR: #{klass} not found" unless element

        unless force
          abort "#{klass} not available in minSdkVersion, added in #{element.attribute('api_added')}; use --force to create it" if
          element.attribute('api_added') and element.attribute('api_added').to_i > verify_min_sdk.to_i
          abort "#{klass} deprecated for targetSdkVersion, deprecatrd in #{element.attribute('deprecated')}; use --force to create it" if
          element.attribute('deprecated') and element.attribute('deprecated').to_i <= verify_target_sdk.to_i
        end

        abort "#{klass} removed for targetSdkVersion, removed in #{element.attribute('api_removed')}" if
        element.attribute('api_removed') and element.attribute('api_removed').to_i <= verify_target_sdk.to_i

        element
      end

      #
      # check_methods: Checks the methods to see if they are available for all api levels
      #
      def check_methods(methods, force=false)
        min_api = verify_min_sdk.to_i
        target_api = verify_target_sdk.to_i

        # Remove methods changed outside of the scope of the sdk versions
        methods = methods.select{|i| not i.attribute('api_added') or i.attribute('api_added').to_i <= target_api}
        methods = methods.select{|i| not i.attribute('deprecated') or i.attribute('deprecated').to_i > min_api}
        methods = methods.select{|i| not i.attribute('api_removed') or i.attribute('api_removed').to_i > min_api}

        # Inform and remove methods that do not exist in one of the sdk versions
        methods = methods.select do |i|
          if i.attribute('api_removed') and i.attribute('api_removed').to_i <= target_api
            puts "Can't create #{i.method_signature} -- removed in #{i.attribute('api_removed')}"
            false
          else
            true
          end
        end

        new_methods = methods
        unless force
          # Inform and remove methods changed inside the scope of the sdk versions
          new_methods = methods.select do |i|
            if i.attribute('api_added') and i.attribute('api_added').to_i > min_api
              puts "Can't create #{i.method_signature} -- added in #{i.attribute('api_added')} -- exclude or force"
              false
            elsif i.attribute('deprecated') and i.attribute('deprecated').to_i <= target_api
              puts "Can't create #{i.method_signature} -- deprecated in #{i.attribute('deprecated')} -- exclude or force"
              false
            else
              true
            end
          end

          abort("Aborting!") if methods.count != new_methods.count
        end

        new_methods
      end

      #
      # generate_subclass_or_interface: Creates a subclass or interface based on the specifications.
      #
      def generate_subclass_or_interface(params)
        defaults = {:template => "InheritingClass", :method_base => "all", :method_include => "", :method_exclude => "", :force => false, :implements => ""}
        params = defaults.merge(params)
        params[:package] = verify_package unless params[:package]

        class_desc = get_class_or_interface(params[:class] || params[:interface], params[:force])

        puts "Generating methods for #{params[:name]}..."
        methods = class_desc.all_methods(params[:method_base], params[:method_include], params[:method_exclude], params[:implements])
        methods = check_methods(methods, params[:force])
        puts "Done. Methods created: #{methods.count}"

        # Remove any duplicate constants (use *args handle multiple parameter lists)
        constants = methods.map(&:constant_string).uniq

        build_file params[:template], params[:package], params[:name], {
          "THE_PACKAGE" => params[:package],
          "THE_ACTION" => class_desc.name == "class" ? "extends" : "implements",
          "THE_ANDROID_CLASS" => (params[:class] || params[:interface]) +
          (params[:implements] == "" ? "" : (" implements " + params[:implements].split(",").join(", "))),
          "THE_RUBOTO_CLASS" => params[:name],
          "THE_CONSTANTS" =>  constants.map {|i| "public static final int #{i} = #{constants.index(i)};"}.indent.join("\n"),
          "CONSTANTS_COUNT" => methods.count.to_s,
          "THE_CONSTRUCTORS" => class_desc.name == "class" ?
          class_desc.get_elements("constructor").map{|i| i.constructor_definition(params[:name])}.join("\n\n") : "",
          "THE_METHODS" => methods.map{|i| i.method_definition}.join("\n\n")
        }
      end

      #
      # generate_core_classe: generates RubotoActivity, RubotoService, etc. based
      #   on the API specifications.
      #
      def generate_core_classes(params)
        %w(android.view.View.OnClickListener android.widget.AdapterView.OnItemClickListener).each do |i|
          name = i.split(".")[-1]
          if(params[:class] == name or params[:class] == "all")
            generate_subclass_or_interface({:package => "org.ruboto.callbacks", :class => i, :name => "Ruboto#{name}"})
          end
        end

        hash = {:package => "org.ruboto"}
        %w(method_base method_include implements force).inject(hash) {|h, i| h[i.to_sym] = params[i.to_sym]; h}
        hash[:method_exclude] = params[:method_exclude].split(",").push("onCreate").push("onReceive").join(",")

        %w(android.app.Activity android.app.Service android.content.BroadcastReceiver android.view.View).each do |i|
          name = i.split(".")[-1]
          if(params[:class] == name or params[:class] == "all")
            generate_subclass_or_interface(
            hash.merge({:template => name == "View" ? "InheritingClass" : "Ruboto#{name}", :class => i, :name => "Ruboto#{name}"}))
          end
        end

        # Activities that can be created, but only directly  (i.e., not included in all)
        %w(android.preference.PreferenceActivity android.app.TabActivity).each do |i|
          name = i.split(".")[-1]
          if params[:class] == name
            generate_subclass_or_interface(hash.merge({:template => "RubotoActivity", :class => i, :name => "Ruboto#{name}"}))
          end
        end
      end

      ###########################################################################
      #
      # generate_inheriting_file:
      #   Builds a script based subclass of Activity, Service, or BroadcastReceiver
      #

      def generate_inheriting_file(klass, name, package, script_name, dest='.', filename = name)
        file = File.join(dest, "src/#{package.gsub('.', '/')}", "#{filename}.java")
        text = File.read(File.join(Ruboto::ASSETS, "src/Inheriting#{klass}.java"))
        File.open(file, 'w') do |f|
          f << text.gsub("THE_PACKAGE", package).gsub("Inheriting#{klass}", name).gsub("start.rb", script_name)
        end

        sample_source = File.read(File.join(Ruboto::ASSETS, "samples/sample_#{underscore klass}.rb")).gsub("THE_PACKAGE", package).gsub("Sample#{klass}", name).gsub("start.rb", script_name)
        FileUtils.mkdir_p File.join(dest, 'assets/scripts')
        File.open File.join(dest, "assets/scripts/#{script_name}"), "a" do |f|
          f << sample_source
        end

        sample_test_source = File.read(File.join(Ruboto::ASSETS, "samples/sample_#{underscore klass}_test.rb")).gsub("THE_PACKAGE", package).gsub("Sample#{klass}", name)
        FileUtils.mkdir_p File.join(dest, 'test/assets/scripts')
        File.open File.join(dest, "test/assets/scripts/#{script_name.chomp('.rb')}_test.rb"), "a" do |f|
          f << sample_test_source
        end
      end
    end
  end
end