# frozen_string_literal: true

module SmartTodo
  class Error < StandardError; end
  class NotFoundError < Error; end
  class ValidationError < Error; end
end
