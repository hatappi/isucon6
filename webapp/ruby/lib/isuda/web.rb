require 'digest/sha1'
require 'json'
require 'net/http'
require 'uri'

require 'erubis'
require 'mysql2'
require 'mysql2-cs-bind'
require 'rack/utils'
require 'sinatra/base'
require 'tilt/erubis'
require 'pry'
require 'stackprof'
require 'rack-lineprof'

module Isuda
  class Web < ::Sinatra::Base

    use Rack::Lineprof
    enable :protection
    enable :sessions

    set :erb, escape_html: true
    set :public_folder, File.expand_path('../../../../public', __FILE__)
    set :db_user, ENV['ISUDA_DB_USER'] || 'root'
    set :db_password, ENV['ISUDA_DB_PASSWORD'] || 'root'
    set :dsn, ENV['ISUDA_DSN'] || 'dbi:mysql:db=isuda'
    set :session_secret, 'tonymoris'
    set :isupam_origin, ENV['ISUPAM_ORIGIN'] || 'http://localhost:5050'
    set :encoded_html_by_keyword, {}
    set :html_description, {}
    set :pattern, ""

    configure :development do
      require 'sinatra/reloader'

      register Sinatra::Reloader
    end

    set(:set_name) do |value|
      condition {
        user_id = session[:user_id]
        if user_id
          user = db.xquery(%| select name from user where id = ? |, user_id).first
          @user_id = user_id
          @user_name = user[:name]
          halt(403) unless @user_name
        end
      }
    end

    set(:authenticate) do |value|
      condition {
        halt(403) unless @user_id
      }
    end

    helpers do
      def db
        Thread.current[:db] ||=
          begin
            _, _, attrs_part = settings.dsn.split(':', 3)
            attrs = Hash[attrs_part.split(';').map {|part| part.split('=', 2) }]
            mysql = Mysql2::Client.new(
              username: settings.db_user,
              password: settings.db_password,
              database: attrs['db'],
              encoding: 'utf8mb4',
              init_command: %|SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY'|,
            )
            mysql.query_options.update(symbolize_keys: true)
            mysql
          end
      end

      def register(name, pw)
        chars = [*'A'..'~']
        salt = 1.upto(20).map { chars.sample }.join('')
        salted_password = encode_with_salt(password: pw, salt: salt)
        db.xquery(%|
          INSERT INTO user (name, salt, password, created_at)
          VALUES (?, ?, ?, NOW())
        |, name, salt, salted_password)
        db.last_id
      end

      def encode_with_salt(password: , salt: )
        Digest::SHA1.hexdigest(salt + password)
      end

      def is_spam_content(content)
        isupam_uri = URI(settings.isupam_origin)
        res = Net::HTTP.post_form(isupam_uri, 'content' => content)
        validation = JSON.parse(res.body)
        validation['valid']
        ! validation['valid']
      end

      def htmlify(pattern, content, id)
        return settings.html_description[id] if settings.html_description[id]

        escaped_content = content.gsub(/(#{pattern})/) {|m|
          matched_keyword = $1
          unless settings.encoded_html_by_keyword[matched_keyword]
            keyword_url = url("/keyword/#{Rack::Utils.escape_path(matched_keyword)}")
            escape_html = Rack::Utils.escape_html(matched_keyword)
            settings.encoded_html_by_keyword[matched_keyword] = [keyword_url, escape_html]
          end
          '<a href="%s">%s</a>' % settings.encoded_html_by_keyword[matched_keyword]
        }

        settings.html_description[id] = escaped_content.gsub(/\n/, "<br />\n")
      end

      def uri_escape(str)
        Rack::Utils.escape_path(str)
      end

      def redirect_found(path)
        redirect(path, 302)
      end
    end

    get '/initialize' do
      db.xquery(%| DELETE FROM entry WHERE id > 7101 |)
      db.xquery('TRUNCATE star')
      keywords = db.xquery(%| select keyword from entry order by character_length(keyword) desc |)
      settings.pattern = keywords.map {|k| Regexp.escape(k[:keyword]) }.join('|')

      content_type :json
      JSON.generate(result: 'ok')
    end

    get '/stars' do
      keyword = params[:keyword] || ''
      stars = db.xquery(%| select * from star where keyword = ? |, keyword).to_a
      content_type :json
      JSON.generate(stars: stars)
    end

    post '/stars' do
      keyword = params[:keyword]
      db.xquery(%| select keyword, description from entry where keyword = ? |, keyword).first or halt(404)
      user_name = params[:user]
      db.xquery(%|
        INSERT INTO star (keyword, user_name, created_at)
        VALUES (?, ?, NOW())
      |, keyword, user_name)
      content_type :json
      JSON.generate(result: 'ok')
    end

    get '/', set_name: true do
      per_page = 10
      page = (params[:page] || 1).to_i

      # entries を cacheできそう
      entries = db.xquery(%|
        SELECT * FROM entry
        ORDER BY updated_at DESC
        LIMIT #{per_page}
        OFFSET #{per_page * (page - 1)}
      |)
      stars = db.xquery(%| select keyword, user_name from star |).to_a
      # starsの検索を、まとめてやれそう。
      
      pattern = settings.pattern
      entries.each do |entry|
        entry[:html] = htmlify(pattern, entry[:description],entry[:id])
        entry[:stars] = stars.select{|s| s[:keyword] == entry[:keyword]}
      end

      total_entries = db.xquery(%| SELECT count(*) AS total_entries FROM entry |).first[:total_entries].to_i
      last_page = (total_entries.to_f / per_page.to_f).ceil
      from = [1, page - 5].max
      to = [last_page, page + 5].min
      pages = [*from..to]
      locals = {
        entries: entries,
        page: page,
        pages: pages,
        last_page: last_page,
      }
      erb :index, locals: locals
    end

    get '/robots.txt' do
      halt(404)
    end

    get '/register', set_name: true do
      erb :register
    end

    post '/register' do
      name = params[:name] || ''
      pw   = params[:password] || ''
      halt(400) if (name == '') || (pw == '')

      user_id = register(name, pw)
      session[:user_id] = user_id

      redirect_found '/'
    end

    get '/login', set_name: true do
      locals = {
        action: 'login',
      }
      erb :authenticate, locals: locals
    end

    post '/login' do
      name = params[:name]
      user = db.xquery(%| select * from user where name = ? |, name).first
      halt(403) unless user
      halt(403) unless user[:password] == encode_with_salt(password: params[:password], salt: user[:salt])

      session[:user_id] = user[:id]

      redirect_found '/'
    end

    get '/logout' do
      session[:user_id] = nil
      redirect_found '/'
    end

    post '/keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] || ''
      halt(400) if keyword == ''
      description = params[:description]
      halt(400) if is_spam_content(description) || is_spam_content(keyword)

      bound = [@user_id, keyword, description] * 2
      db.xquery(%|
        INSERT INTO entry (author_id, keyword, description, created_at, updated_at)
        VALUES (?, ?, ?, NOW(), NOW())
        ON DUPLICATE KEY UPDATE
        author_id = ?, keyword = ?, description = ?, updated_at = NOW()
      |, *bound)

      keywords = db.xquery(%| select keyword from entry order by character_length(keyword) desc |)
      settings.pattern = keywords.map {|k| Regexp.escape(k[:keyword]) }.join('|')

      entries = db.xquery(%| select id, keyword, description from entry where description LIKE ? |, keyword)
      entries.each do |entry|
        htmlify(settings.pattern, entry[:description], entry[:id])
      end

      redirect_found '/'
    end

    get '/keyword/:keyword', set_name: true do
      keyword = params[:keyword] or halt(400)
      stars = db.xquery(%| select keyword, user_name from star where keyword =? |, keyword).to_a
      entry = db.xquery(%| select id, keyword, description from entry where keyword = ? |, keyword).first or halt(404)
      pattern = settings.pattern
      entry[:stars] = stars
      entry[:html] = htmlify(pattern, entry[:description], entry[:id])
      erb :keyword, locals: { entry: entry }
    end

    post '/keyword/:keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] or halt(400)
      is_delete = params[:delete] or halt(400)
      unless db.xquery(%| SELECT * FROM entry WHERE keyword = ? |, keyword).first
        halt(404)
      end
      db.xquery(%| DELETE FROM entry WHERE keyword = ? |, keyword)
      keywords = db.xquery(%| select keyword from entry order by character_length(keyword) desc |)
      settings.pattern = keywords.map {|k| Regexp.escape(k[:keyword]) }.join('|')

      entries = db.xquery(%| select id, keyword, description from entry where description LIKE ? |, keyword)
      entries.each do |entry|
        htmlify(settings.pattern, entry[:description], entry[:id])
      end

      redirect_found '/'
    end
  end
end

# work with local
# Isuda::Web.run!
