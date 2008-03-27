# $Id$

require 'find'
require 'fileutils'
require 'erb'

module Webby

# The Builder class performs the work of scanning the content folder,
# creating Resource objects, and converting / copying the contents to the
# output folder as needed.
#
class Builder

  class << self

    # call-seq:
    #    Builder.run( :rebuild => false )
    #
    # Create a new instance of the Builder class and invoke the run method.
    # If the <code>:rebuild</code> option is given as +true+, then all pages
    # will be recreated / copied.
    #
    def run( opts = {} )
      self.new.run opts
    end

    # call-seq:
    #    Builder.create( type, opts = {} )
    #
    # Create a new page type where type can be one of :page, :partial,
    # :blog. The options hash should include the Rake task object being used
    # to create the page and the template from which the page is to be
    # created.
    #
    #    create( :page, :from => template, :task => rake_task )
    #
    def create( type, opts = {} )
      task = opts.delete(:task)
      raise "rake task must be given in the options hash" if task.nil?
      raise "Usage:  rake #{task.name} path" unless ARGV.length > 1

      page = task.application.top_level_tasks.slice!(1..-1).join('-')
      name = ::Webby::Resources::File.basename(page)
      ext  = ::Webby::Resources::File.extname(page)
      dir  = ::File.dirname(page)
      dir  = '' if dir == '.'

      locals = opts[:locals] || {}
      locals[:title] = name.split('-').map {|w| w.capitalize}.join(' ')
      opts[:locals] = locals

      case type
      when :partial
        name = '_' + name
        page = ::File.join(::Webby.site.content_dir, dir, name)
        page << '.' << (ext.empty? ? 'txt' : ext)

      when :page
        if ::Webby.site.create_mode == 'directory'
          page = ::File.join(::Webby.site.content_dir, dir, name, 'index')
          page << '.' << (ext.empty? ? 'txt' : ext)
        else
          page = ::File.join(::Webby.site.content_dir, page)
          page << '.txt' if ext.empty?
        end

      when :blog
        dir = create_blog_directory(dir)
        if ::Webby.site.create_mode == 'directory'
          page = ::File.join(dir, name, 'index')
          page << '.' << (ext.empty? ? 'txt' : ext)
        else
          page = ::File.join(dir, name)
          page << '.txt' if ext.empty?
        end

      else raise "cannot create unknown type #{type.inspect}" end

      create_page(page, opts)
      exec(::Webby.editor, page) unless ::Webby.editor.nil?
    end

    # call-seq:
    #    Builder.create_page( page, :from => template, :locals => {} )
    #
    # This mehod is used to create a new _page_ in the content folder based
    # on the specified template. _page_ is the relative path to the new page
    # from the <code>content/</code> folder. The _template_ is the name of
    # the template to use from the <code>templates/</code> folder.
    #
    def create_page( page, opts = {} )
      tmpl = opts[:from]
      raise Error, "template not given" unless tmpl
      raise Error, "#{page} already exists" if test ?e, page

      Logging::Logger[self].info "creating #{page}"
      FileUtils.mkdir_p ::File.dirname(page)

      context = scope
      opts[:locals].each do |k,v|
        Thread.current[:value] = v
        definition = "#{k} = Thread.current[:value]"
        eval(definition, context)
      end if opts.has_key?(:locals)

      str = ERB.new(::File.read(tmpl), nil, '-').result(context)
      ::File.open(page, 'w') {|fd| fd.write str}

      return nil
    end

    # call-seq:
    #    Builder.create_blog_directory( dir )    => string
    #
    # Takes the given directory, converts it to a date based blog directory,
    # and ensures that index files exist for the year and month directories.
    # The default blog directory looks like the following:
    #
    #    articles/2008/03/27/your-blog-post
    #
    # The default "articles" directory can be changed by setting the
    # "SITE.blog_dir" entry in the website Rakefile.
    #
    def create_blog_directory( dir )
      now   = Time.now
      year  = now.strftime '%Y'
      month = now.strftime '%m'
      day   = now.strftime '%d'

      # if no directory was given use the default blog directory (underneath
      # the content directory)
      dir = ::Webby.site.blog_dir if dir.empty?

      # create the index file for the current month directory
      fn = ::File.join(::Webby.site.content_dir, dir, year, month, 'index.txt')
      tmpl = Dir.glob(::File.join(::Webby.site.template_dir, 'blog_month.*')).first.to_s
      if test(?f, tmpl) and not test(?f, fn)
        create_page(fn, :from => tmpl,
            :locals => {:title => now.strftime('%B %Y')})
      end

      # create the index file for the current year directory
      fn = ::File.join(::Webby.site.content_dir, dir, year, 'index.txt')
      tmpl = Dir.glob(::File.join(::Webby.site.template_dir, 'blog_year.*')).first.to_s
      if test(?f, tmpl) and not test(?f, fn)
        create_page(fn, :from => tmpl,
            :locals => {:title => now.strftime('%Y')})
      end

      # return the directory where this blog post should be created
      ::File.join(::Webby.site.content_dir, dir, year, month, day)
    end


    private

    # Returns the binding in the scope of the Builder class object.
    #   
    def scope() binding end

  end  # class << self

  # call-seq:
  #    Builder.new
  #
  # Creates a new Builder object for creating pages from the content and
  # layout directories.
  #
  def initialize
    @log = Logging::Logger[self]
  end

  # call-seq:
  #    run( :rebuild => false, :load_files => true )
  #
  # Runs the Webby builder by loading in the layout files from the
  # <code>layouts/</code> folder and the content from the
  # <code>contents/</code> folder. Content is analyzed, and those that need
  # to be copied or compiled (filtered using ERB, Texttile, Markdown, etc.)
  # are handled. The results are placed in the <code>output/</code> folder.
  #
  # If the <code>:rebuild</code> flag is set to +true+, then all content is
  # copied and/or compiled to the output folder.
  #
  # A content file can mark itself as dirty by setting the +dirty+ flag to
  # +true+ in the meta-data of the file. This will cause the contenet to
  # always be compiled when the builder is run. Conversely, setting the
  # dirty flag to +false+ will cause the content to never be compiled or
  # copied to the output folder.
  #
  # A content file needs to be built if the age of the file is less then the
  # age of the output product -- i.e. the content file has been modified
  # more recently than the output file.
  #
  def run( opts = {} )
    opts[:load_files] = true unless opts.has_key?(:load_files)

    unless test(?d, output_dir)
      @log.info "creating #{output_dir}"
      FileUtils.mkdir output_dir
    end

    load_files if opts[:load_files]

    Resources.pages.each do |page|
      next unless page.dirty? or opts[:rebuild]

      @log.info "creating #{page.destination}"

      # make sure the directory exists
      FileUtils.mkdir_p ::File.dirname(page.destination)

      # copy the resource to the output directory if it is static
      if page.instance_of? Resources::Static
        FileUtils.cp page.path, page.destination
        FileUtils.chmod 0644, page.destination

      # otherwise, layout the resource and write the results to
      # the output directory
      else Renderer.write(page) end
    end

    # touch the cairn so we know when the website was last generated
    FileUtils.touch ::Webby.cairn

    nil
  end


  private

  # Scan the <code>layouts/</code> folder and the <code>content/</code>
  # folder and create a new Resource object for each file found there.
  #
  def load_files
    ::Find.find(layout_dir, content_dir) do |path|
      next unless test ?f, path
      next if path =~ ::Webby.exclude
      Resources.new path
    end
  end

  %w(output_dir layout_dir content_dir).each do |key|
    self.class_eval <<-CODE
      def #{key}( ) ::Webby.site.#{key} end
    CODE
  end

end  # class Builder
end  # module Webby

# EOF
