require 'set'

class Comment < ApplicationRecord
  belongs_to :commentable, polymorphic: true # belongs to a Project, Package or BsRequest
  belongs_to :user, inverse_of: :comments

  validates :body, :commentable, :user, presence: true
  # FIXME: this probably should be MEDIUMTEXT(16MB) instead of text (64KB)
  validates :body, length: { maximum: 65_535 }
  validates :body, format: { with: /\A[^\u0000]*\Z/,
                             message: 'must not contain null characters' }

  validate :validate_parent_id

  after_create :create_notification
  after_destroy :delete_parent_if_unused

  has_many :children, dependent: :destroy, class_name: 'Comment', foreign_key: 'parent_id'
  has_many :notifications, as: :notifiable, dependent: :delete_all

  extend ActsAsTree::TreeWalker
  acts_as_tree order: 'created_at'

  scope :without_parent, -> { where(parent_id: nil) }

  def to_s
    body
  end

  def blank_or_destroy
    if children.exists?
      self.body = 'This comment has been deleted'
      self.user = User.find_nobody!
      save!
    else
      destroy
    end
  end

  private

  def create_notification(params = {})
    params[:id] = id
    params[:commenter] = user.login
    params[:comment_body] = body
    params[:commenters] = involved_users

    case commentable_type
    when 'Package'
      params[:package] = commentable.name
      params[:project] = commentable.project.name
      # call the action
      Event::CommentForPackage.create(params)
    when 'Project'
      params[:project] = commentable.name
      # call the action
      Event::CommentForProject.create(params)
    when 'BsRequest'
      params = commentable.notify_parameters(params)
      # params[:id] got overwritten with notify_parameters. We need to assign it again
      params[:id] = id
      # call the action
      Event::CommentForRequest.create(params)
    end
  end

  def delete_parent_if_unused
    parent.destroy if parent && parent.user.is_nobody? && parent.children.length.zero?
  end

  # build an array of users, commenting or being mentioned on the commentable of this comment
  def involved_users
    users = Set.new
    users_mentioned = Set.new
    Comment.where(commentable: commentable).includes(:user).find_each do |comment|
      # take the one making the comment
      users << comment.user.login
      # check if users are mentioned (regexp borrowed from user model - with whitespace removed)
      comment.body.scan(%r{@([\w\^\-\.#\*\+&'"]*)}).each do |user_login|
        users_mentioned << user_login.first
      end
    end
    users += User.where(login: users_mentioned).pluck(:login)
    users.to_a
  end

  def validate_parent_id
    return unless parent_id
    return if commentable.comments.where(id: parent_id).present?
    errors.add(:parent, 'belongs to different object')
  end
end

# == Schema Information
#
# Table name: comments
#
#  id               :integer          not null, primary key
#  body             :text(65535)
#  parent_id        :integer          indexed
#  created_at       :datetime
#  updated_at       :datetime
#  user_id          :integer          not null, indexed
#  commentable_type :string(255)      indexed => [commentable_id]
#  commentable_id   :integer          indexed => [commentable_type]
#
# Indexes
#
#  index_comments_on_commentable_type_and_commentable_id  (commentable_type,commentable_id)
#  parent_id                                              (parent_id)
#  user_id                                                (user_id)
#
# Foreign Keys
#
#  comments_ibfk_1  (user_id => users.id)
#  comments_ibfk_4  (parent_id => comments.id)
#
