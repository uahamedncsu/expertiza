# TODO 
# Fix views - edit 'show' and partials - Bria may work on partial formatting
# Bidding data - 
# Route correctly - Ryan will look into 

class ReviewBidsController < ApplicationController
  require "json"
  require "net/http"

  # before_action :set_review_bid, only: [:show, :edit, :update, :destroy]

  #action allowed function checks the action allowed based on the user working
  def action_allowed?
    case params[:action]
    when 'show', 'review_bid', 'assign_review_priority'
      ['Instructor',
       'Teaching Assistant',
       'Administrator',
       'Super-Administrator',
       'Student'].include? current_role_name and
      ((%w[list].include? action_name) ? are_needed_authorizations_present?(params[:id], "participant" "reader", "submitter", "reviewer") : true)
    else
      ['Instructor',
       'Teaching Assistant',
       'Administrator',
       'Super-Administrator'].include? current_role_name
    end
  end  

  # GET /review_bids
  def index
    @review_bids = ReviewBid.all
  end

  # GET /review_bids/1
  def show
    # params[:id] = 36221 # TODO remove this line 
    #params[:id] = 36242
    @participant =  AssignmentParticipant.find(params[:id].to_i)
    @assignment = @participant.assignment
    @sign_up_topics = SignUpTopic.where(assignment_id: @assignment.id)
	@selected_topics = []
    @max_team_size = @assignment.max_team_size
    @bids = ReviewBid.where(participant_id:@participant,assignment_id:@assignment.id).order(:priority)
  end

  # GET /review_bids/new
  def new
    @review_bid = ReviewBid.new
  end

  # GET /review_bids/1/edit
  def edit
  end

  # POST /review_bids
  def create
    # @review_bid = ReviewBid.new(review_bid_params)
    # if @review_bid.save
    #   redirect_to @review_bid, notice: 'Review bid was successfully created.'
    # else
    #   render :new
    # end
  end


  # assign bidding topics to reviewers
  def assign_bidding
	#parameters for running bidding algorithm
    assignment_id = params[:id]
    reviewers = ReviewBid.reviewers(assignment_id) # TODO (maybe finished) create to get list of reviewers
    topics = SignUpTopic.where(assignment_id: assignment_id).ids
    bidding_data = ReviewBid.get_bidding_data(assignment_id,reviewers) # TODO create this function with info we want for WebService

	#runs algorithm and assigns reviews
    matched_topics = run_bidding_algorithm(bidding_data,topics,assignment_id) # TODO already started, adjust for our values
    ReviewBid.assign_review_topics(assignment_id,reviewers,matched_topics) # TODO create to assign the return matching reviews to students
    Assignment.find(assignment_id).update(can_choose_topic_to_review: false)  #turns off bidding for students
    redirect_to :back
  end

  # call webserver for running assigning algorthim
  # passing webserver: student_ids, topic_ids, student_preferences, topic_preferences
  # webserver returns: 
  # returns matched assignments as json body
  def run_bidding_algorithm(bidding_data,topics,assignment_id)
    # begin
      num_reviews_allowed = Assignment.where(id:assignment_id).pluck(:num_reviews_allowed).first
      raw_webserver_input_hash = {"users": bidding_data, "tids": topics, "q_S": num_reviews_allowed} #TODO adjust hash values
      uri = URI.parse(WEBSERVICE_CONFIG["review_bidding_webservice_url"])
      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Post.new(uri.path, {'Content-Type' => 'application/json'})
      http.use_ssl = true
      request.body = raw_webserver_input_hash.to_json
      response = http.request(request)
      return JSON.parse(response.body)
    rescue StandardError
      return false
    # end
  end

end
