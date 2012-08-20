#!/usr/bin/env ruby

require 'sinatra'
require 'erb'
require 'sequel'
require 'sinatra/cookies'
require 'json'
require 'logger'

class NoSuchQuestion < Exception
end

class InvalidInput < Exception
end

#set :server, :thin
DB = Sequel.connect('sqlite://survey.sqlite3', :logger => Logger.new('db.log'))
enable :sessions
set :session_secret, "something long and hard to guess"

def users_hospice(question, user, session, params)
    puts "Processing step 1, got text: " + params["ac-input"]
    if params["ac-input"] =~ /^([A-Za-z' ]+)$/  # No funny characters in the name.
      cleaned_input = $1
    else
      raise InvalidInput
    end
    hospice = DB[:hospices][:name => cleaned_input]
    if hospice.nil?
      hospice_id = DB[:hospices].insert(:name => cleaned_input)
    else
      hospice_id = hospice[:id]
    end
    answer_set_id = DB[:answer_sets].insert(:timestamp => Time.now(), :question_id => question[:id], :user_id => user)
    answer_id = DB[:hospice_answers].insert(:answer_set_id => answer_set_id, :hospice_id => hospice_id)
    puts "Recorded answer: #{answer_id}"
end

def work_function_ranking(question, user, session, params)
  mapping = session[:work_function_mapping]
  values = mapping.values
  rearrangement = params["arrangement"].scan(/item_\d+/).map {|i| i =~ /(\d+)$/; $1.to_i }
  puts "Rearrangement: " + rearrangement.join(',')
  puts "Mapping values: " + values.sort.join(',')
  unless (rearrangement.sort == values.sort)
    raise InvalidInput
  end
  order_by_dbid = rearrangement.map {|i| (mapping.invert)[i]}
  answer_set_id = DB[:answer_sets].insert(:timestamp => Time.now(), :question_id => question[:id], :user_id => user)
  puts "Proper arrangement: " + order_by_dbid.join(',')
  order_by_dbid.each.with_index do |dbid, rank|
    DB[:rank_answers].insert(:answer_set_id => answer_set_id, :work_function_id => dbid, :rank => rank)
  end
end

def work_function_selection(question, user, session, params)
  
end

# If the browser isn't already from around here, start them 
# at the right place, make a new user, and give a cookie.
before do
  puts "Request for: #{request.url} - running before..."
  if ((session[:ip_address] != request.ip) or
      (session[:created_at] < (Time.now() - 60 * 10))) # Session older than 10 minutes?
    puts "This looks like a new user!"
    session[:ip_address] = request.ip
    session[:created_at] = Time.now()
    user_id = DB[:users].insert(:ip_address => request.ip,
                          :referrer => request.referrer,
                          :created_at => session[:created_at])
    session[:user_id] = user_id
    redirect "/step/1", 302
  end
end

get "/" do
  redirect "/step/1", 302
end

get %r{^/step/(\d+)} do |i|
  step = i.to_i
  question = DB[:questions][:id => step]
  if question.nil?
    raise NoSuchQuestion, step
  end
  r = Random.new((Time.now.to_f * 1000).to_i)
  case question[:question_type_id]
  when 1
    n = DB[:work_functions].count
    work_fns = DB[:work_functions].sort_by { r.rand }.to_a
    shuffled_order = work_fns.map{|f| f[:id]}
    mapping = {}
    (1..n).to_a.zip(shuffled_order) {|i, j| mapping[j] = i}
    session[:work_function_mapping] = mapping
    erb :rank, :locals => {:q => question, :s => step, :work_fns => work_fns}
  when 2
    work_fns = DB[:work_functions].sort_by { r.rand }.to_a
    session[:work_function_order] = work_fns.map {|wf| wf[:id]}
    erb :multiple_selection, :locals => {:q => question, :s => step, :work_fns => work_fns}
  when 3
    completions = DB[:hospices].order(:name).map {|h| h[:name] }.to_json
    erb :single_selection_or_text_entry,
      :locals => {:q => question, :s => step,
                  :c => completions}
  else
    "Oops."
  end
  # erb :step, :locals => {:s => step}
end

post %r{^/step/(\d+)} do |i|
  step = i.to_i
  question = DB[:questions][:id => step]
  if question.nil?
    raise NoSuchQuestion, step
  end
  number_of_questions = DB[:questions].count
  if step > number_of_questions
    raise NoSuchQuestion, step
  end

  user = session[:user_id]

  case step
  when 1
    users_hospice(question, user, session, params)
  when 2
    work_function_ranking(question, user, session, params)
  when 3
    work_function_ranking(question, user, session, params)
  when 4
    work_function_selection(question, user, session, params)
  when 5
    work_function_selection(question, user, session, params)
  else
    "Oops."
  end

  # Process answer for question
  
  if (step < number_of_questions)
    next_step = i.to_i.succ
    next_path = "/step/#{next_step}"
    redirect next_path, 302
  elsif (number_of_questions == step)
    redirect "/done", 302
  else
    "Hmm. Not sure what to do here."
  end
end

get "/done" do
  erb :done
end
