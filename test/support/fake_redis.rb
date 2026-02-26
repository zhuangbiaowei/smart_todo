# frozen_string_literal: true

require 'set'

class FakeRedis
  def initialize
    @hashes = Hash.new { |h, k| h[k] = {} }
    @sets = Hash.new { |h, k| h[k] = Set.new }
    @lists = Hash.new { |h, k| h[k] = [] }
    @zsets = Hash.new { |h, k| h[k] = {} }
  end

  def multi
    yield self
  end

  def hset(key, field, value = nil)
    if field.is_a?(Hash)
      @hashes[key].merge!(field.transform_values { |v| serialize(v) })
    else
      @hashes[key][field] = serialize(value)
    end
    true
  end

  def hgetall(key)
    @hashes[key].dup
  end

  def hdel(key, *fields)
    fields.flatten.each { |field| @hashes[key].delete(field.to_s) }
    true
  end

  def sadd(key, *members)
    members.flatten.each { |member| @sets[key].add(serialize(member)) }
    true
  end

  def srem(key, *members)
    members.flatten.each { |member| @sets[key].delete(serialize(member)) }
    true
  end

  def smembers(key)
    @sets[key].to_a
  end

  def zadd(key, score, member)
    @zsets[key][serialize(member)] = score.to_f
    true
  end

  def zrem(key, *members)
    members.flatten.each { |member| @zsets[key].delete(serialize(member)) }
    true
  end

  def rpush(key, value)
    @lists[key] << serialize(value)
    true
  end

  def lrange(key, start_idx, stop_idx)
    list = @lists[key]
    return [] if list.empty?

    start_idx = normalize_index(start_idx, list.length)
    stop_idx = normalize_index(stop_idx, list.length)
    return [] if start_idx.nil? || stop_idx.nil? || start_idx > stop_idx

    list[start_idx..stop_idx] || []
  end

  def del(*keys)
    keys.flatten.each do |key|
      @hashes.delete(key)
      @sets.delete(key)
      @lists.delete(key)
      @zsets.delete(key)
    end
    true
  end

  private

  def serialize(value)
    value.nil? ? nil : value.to_s
  end

  def normalize_index(index, size)
    return nil if size.zero?
    return index if index >= 0

    normalized = size + index
    normalized.negative? ? 0 : normalized
  end
end
