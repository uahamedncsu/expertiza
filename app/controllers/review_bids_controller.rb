# TODO 
# Bidding data - 
# Routing to bidding vs routing to reviewing. 
# clean up code,ie remove unused variables, refactor some code,or some things, remove unecessary methods
class ReviewBidsController < ApplicationController
  require "json"
  require "uri"
  require "net/http"
  require "rest_client"

  #action allowed function checks the action allowed based on the user working
  def action_allowed?
    case params[:action]
    when 'show', 'review_bid', 'set_priority', 'index'
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
  def index #TODO: remove unused variables. 
    # @participant = AssignmentParticipant.find(params[:id].to_i)
    # @assignment = @participant.assignment
    # @topic_id = SignedUpTeam.topic_id(@participant.parent_id, @participant.user_id)
    @participant = AssignmentParticipant.find(params[:id])
    return unless current_user_id?(@participant.user_id)

    @assignment = @participant.assignment
    # Finding the current phase that we are in
    due_dates = AssignmentDueDate.where(parent_id: @assignment.id)
    @very_last_due_date = AssignmentDueDate.where(parent_id: @assignment.id).order("due_at DESC").limit(1)
    next_due_date = @very_last_due_date[0]
    for due_date in due_dates
      if due_date.due_at > Time.now
        next_due_date = due_date if due_date.due_at < next_due_date.due_at
      end
    end

    @review_phase = next_due_date.deadline_type_id
    if next_due_date.review_of_review_allowed_id == DeadlineRight::LATE or next_due_date.review_of_review_allowed_id == DeadlineRight::OK
      @can_view_metareview = true if @review_phase == DeadlineType.find_by(name: "metareview").id
    end

    @review_mappings = ReviewResponseMap.where(reviewer_id: @participant.id)
    @review_of_review_mappings = MetareviewResponseMap.where(reviewer_id: @participant.id)

	@num_reviews_completed = 0
    @review_mappings.each do |map|
      @num_reviews_completed += 1 if !map.response.empty? && map.response.last.is_submitted
    end
    render 'review_bids/others_work'
  end

  # GET /review_bids/1
  def show 
    @participant = AssignmentParticipant.find(params[:id].to_i)
    @assignment = @participant.assignment
    @sign_up_topics = SignUpTopic.where(assignment_id: @assignment.id, private_to: nil)
    team_id = @participant.team.try(:id)
    my_topic = SignedUpTeam.where(team_id: team_id).pluck(:topic_id).first
    @sign_up_topics -= SignUpTopic.where(assignment_id: @assignment.id, id: my_topic)
    # @max_team_size = @assignment.num_reviews_allowed  #dont need this
    @num_participants = AssignmentParticipant.where(parent_id: @assignment.id).count
    @selected_topics = nil #this is used to list the topics assigned to review. (ie select == assigned i believe)
    @bids = team_id.nil? ? [] : ReviewBid.where(participant_id:@participant,assignment_id:@assignment.id).order(:priority)
    signed_up_topics = []
    @bids.each do |bid|
      sign_up_topic = SignUpTopic.find_by(id: bid.signuptopic_id)
      signed_up_topics << sign_up_topic if sign_up_topic
    end
    signed_up_topics &= @sign_up_topics
    @sign_up_topics -= signed_up_topics
    @bids = signed_up_topics
    @num_of_topics = @sign_up_topics.size
    @assigned_review_maps = []
    selected_topics = []
    ReviewResponseMap.where({:reviewed_object_id => @assignment.id, :reviewer_id => @participant.id}).each do |review_map|
      @assigned_review_maps << review_map
	  end
  end
  
  def set_priority
    if params[:topic].nil?
      ReviewBid.where(participant_id: params[:id]).destroy_all
    else
      participant = AssignmentParticipant.find_by(id: params[:id])
      assignment_id = SignUpTopic.find(params[:topic].first).assignment.id
      # team_id = participant.team.try(:id)
      @bids = ReviewBid.where(participant_id: params[:id])
      signed_up_topics = ReviewBid.where(participant_id: params[:id]).map(&:signuptopic_id)
      signed_up_topics -= params[:topic].map(&:to_i)
      signed_up_topics.each do |topic|
        ReviewBid.where(signuptopic_id: topic, participant_id: params[:id]).destroy_all
      end
      params[:topic].each_with_index do |topic_id, index|
        bid_existence = ReviewBid.where(signuptopic_id: topic_id, participant_id: params[:id])
        if bid_existence.empty?
          ReviewBid.create(priority: index + 1,signuptopic_id: topic_id, participant_id: params[:id],assignment_id: assignment_id)
        else
          ReviewBid.where(signuptopic_id: topic_id, participant_id: params[:id]).update_all(priority: index + 1)
        end
      end
    end
    redirect_to action: 'show', assignment_id: params[:assignment_id], id: params[:id]
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
      assignment_id = params[:assignment_id]
      reviewers = ReviewBid.reviewers(assignment_id) 
      bidding_data = ReviewBid.get_bidding_data(assignment_id,reviewers) 
      
      #runs algorithm and assigns reviews
      matched_topics = run_bidding_algorithm(bidding_data)
      #render 'review_bids/assign_bidding'
      ReviewBid.assign_review_topics(assignment_id,reviewers,matched_topics) 
      Assignment.find(assignment_id).update(can_choose_topic_to_review: false)  #turns off bidding for students
      redirect_to :back

    end

  # call webserver for running assigning algorthim
  # passing webserver: student_ids, topic_ids, student_preferences, time_stamps
  # webserver returns: 
  # returns matched assignments as json body
  def run_bidding_algorithm(bidding_data)
    # begin
      url = WEBSERVICE_CONFIG["review_bidding_webservice_url"] #won't work unless ENV variables are configured
      url = 'https://app-csc517.herokuapp.com/match_topics' #hard coding for the time being
      response = RestClient.post url, bidding_data.to_json, content_type: 'application/json', accept: :json
      return JSON.parse(response.body)
    rescue StandardError
      return false
    # end
  end

end
