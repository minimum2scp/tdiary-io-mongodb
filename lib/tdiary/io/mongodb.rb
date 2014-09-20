# -*- coding: utf-8 -*-
#
# mongodb.rb: MongoDB IO for tDiary 3.x
#
# NAME             mongodb
#
# DESCRIPTION      tDiary IO class on MongoDB
#                  Saving Diary data to MongoDB, but Referer data
#
# Copyright        (C) 2013 TADA Tadashi <t@tdtds.jp>
#
# You can distribute this under GPL.

require 'tdiary/io/base'
require 'tempfile'
require 'mongoid'

module TDiary
	module IO
		class MongoDB < Base
			class Conf
				include Mongoid::Document
				include Mongoid::Timestamps
				store_in collection: "conf"

				field :body, type: String
			end

			class Comment
				include Mongoid::Document
				include Mongoid::Timestamps
				store_in collection: "comments"

				belongs_to :diary
				field :name, type: String
				field :mail, type: String
				field :body, type: String
				field :last_modified, type: String
				field :visible, type: Boolean
			end
	
			class Referer
				include Mongoid::Document
				include Mongoid::Timestamps
				store_in collection: "referers"
			end

			class Diary
				include Mongoid::Document
				include Mongoid::Timestamps
				store_in collection: "diaries"
				
				field :diary_id, type: String
				field :year, type: String
				field :month, type: String
				field :day, type: String
				field :title, type: String
				field :body, type: String
				field :style, type: String
				field :last_modified, type: Integer
				field :visible, type: Boolean
				has_many :comments, autosave: true
				has_many :referers, autosave: true

				index({diary_id: 1}, {unique: true})
				index('comments.no' => 1)
			end
	
			include Cache

			class << self
				def load_cgi_conf(conf)
					db(conf)
					if cgi_conf = Conf.all.first
						cgi_conf.body
					else
						""
					end
				end

				def save_cgi_conf(conf, result)
					db(conf)
					if cgi_conf = Conf.all.first
						cgi_conf.body = result
						cgi_conf.save
					else
						Conf.create(body: result).save
					end
				end

				def db(conf)
					@@_db ||= Mongoid::Config.load_configuration(
						{sessions:{default:{uri:(conf.database_url || 'mongodb://localhost:27017/tdiary')}}}
					)
				end
			end

			#
			# block must be return boolean which dirty diaries.
			#
			def transaction(date)
				diaries = {}

				if cache = restore_parser_cache(date)
					diaries.update(cache)
				else
					restore(date.strftime("%Y%m%d"), diaries)
				end

				dirty = yield(diaries) if iterator?

				store(diaries, dirty)

				store_parser_cache(date, diaries) if dirty || !cache
			end

			def calendar
				calendar = Hash.new{|hash, key| hash[key] = []}
				Diary.all.map{|d|[d.year, d.month]}.sort.uniq.each do |ym|
					calendar[ym[0]] << ym[1]
				end
				calendar
			end

			def cache_dir
				@tdiary.conf.cache_path || "#{Dir.tmpdir}/cache"
			end

		private

			def restore(date, diaries, month = true)
				query = if month && /(\d{4})(\d\d)(\d\d)/ =~ date
							  Diary.where(year: $1, month: $2)
						  else
							  Diary.where(diary_id: date)
						  end
				query.each do |d|
					style = (d.style.nil? || d.style.empty?) ? 'wiki' : d.style.downcase
					diary = eval("#{style(style)}::new(d.diary_id, d.title, d.body, Time::at(d.last_modified.to_i))")
					diary.show(d.visible)
					d.comments.each do |c|
						comment = TDiary::Comment.new(c.name, c.mail, c.body, Time.at(c.last_modified.to_i))
						comment.show = c.visible
						diary.add_comment(comment)
					end
					diaries[d.diary_id] = diary
				end
			end

			def store(diaries, dirty)
				if dirty
					diaries.each do |diary_id, diary|
						year, month, day = diary_id.scan(/(\d{4})(\d\d)(\d\d)/).flatten
	
						entry = Diary.where(diary_id: diary_id).first

						if (dirty & TDiary::TDiaryBase::DIRTY_DIARY) != 0
							if entry
								entry.title = diary.title
								entry.last_modified = diary.last_modified.to_i
								entry.style = diary.style
								entry.visible = diary.visible?
								entry.body = diary.to_src
								entry.save
							else
								Diary.create(
									diary_id: diary_id,
									year: year, month: month, day: day,
									title: diary.title,
									last_modified: diary.last_modified,
									style: diary.style,
									visible: diary.visible?,
									body: diary.to_src
								).save
							end
						end
						if entry && ((dirty & TDiary::TDiaryBase::DIRTY_COMMENT) != 0)
							exist_comments = entry.comments.size
							no = 0
							diary.each_comment(diary.count_comments(true)) do |com|
								if no < exist_comments
									entry.comments[no].name = com.name
									entry.comments[no].mail = com.mail
									entry.comments[no].body = com.body
									entry.comments[no].last_modified = com.date.to_i
									entry.comments[no].visible = com.visible?
									no += 1
								else
									entry.comments.build(
										name: com.name,
										mail: com.mail,
										body: com.body,
										last_modified: com.date.to_i,
										visible: com.visible?
									)
								end
								entry.save
							end
						end
					end
				end
			end

			def db
				self.class.db(@tdiary.conf)
			end
		end
	end
end
