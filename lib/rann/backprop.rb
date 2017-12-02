require "bigdecimal"
require "bigdecimal/util"
require "parallel"
require "rann/gradient_checker"
require "rann/util/array_ext"
require "rann/optimisers/adagrad"
require "rann/optimisers/rmsprop"

module RANN
  class Backprop
    include Util::ArrayExt

    ACTIVATION_DERIVATIVES = {
      relu:   ->(x){ x > 0 ? 1.to_d : 0.to_d },
      sig:    ->(x){ x.mult(1 - x, RANN.d) },
      linear: ->(_){ 1.to_d },
      tanh:   ->(x){ 1 - x.power(2, RANN.d) },
      step:   ->(_){ 0.to_d },
    }

    attr_accessor :network

    def initialize network, opts = {}
      @network          = network
      @connections_hash = network.connections.each.with_object({}){ |c, h| h[c.id] = c }
      @optimiser        = RANN::Optimisers.const_get(opts[:optimiser] || 'RMSProp').new opts
      @batch_count      = 0.to_d
    end

    def run_batch inputs, targets, opts = {}
      @batch_count += 1

      batch_size      = inputs.size
      avg_gradients   = Hash.new{ |h, k| h[k] = 0 }
      avg_batch_error = 0

      # force longer bits of work per iteration, to maximise CPU usage less
      # marshalling data and process overhead etc. best for small networks. for
      # larger networks where one unit of work takes a long time, and the work
      # can vary in time taken, use num_groups == inputs.size
      num_groups     = opts[:num_groups] || ([1, opts[:processes]].max * 10)
      grouped_inputs = in_groups(inputs, num_groups, false).reject &:empty?
      reduce_proc =
        lambda do |_, _, result|
          group_avg_gradients, group_avg_error = result

          avg_gradients.merge!(group_avg_gradients){ |_, o, n| o + n }
          avg_batch_error += group_avg_error
        end

      Parallel.each_with_index(
        grouped_inputs,
        in_processes: opts[:processes],
        finish: reduce_proc
      ) do |inputs, i|
        group_avg_gradients = Hash.new{ |h, k| h[k] = 0.to_d }
        group_avg_error = 0.to_d

        inputs.each_with_index do |input, j|
          gradients, error = Backprop.run_single network, input, targets[i + j]

          gradients.each do |cid, g|
            group_avg_gradients[cid] += g.div batch_size, RANN.d
          end
          group_avg_error += error.div batch_size, RANN.d
        end

        group_avg_gradients.default_proc = nil
        [group_avg_gradients, group_avg_error]
      end

      if opts[:checking]
        # check assumes batchsize 1 for now
        sorted_gradients = avg_gradients.values_at *network.connections.map(&:id)
        invalid = GradientChecker.check network, inputs.first, targets.first, sorted_gradients
        if invalid.empty?
          puts "gradient valid"
        else
          puts "gradients INVALID for connections:"
          invalid.each do |i|
            puts "#{network.connections[i].input_neuron.name} -> #{network.connections[i].output_neuron.name}"
          end
        end
      end

      avg_gradients.each do |con_id, gradient|
        con = @connections_hash[con_id]
        next if con.locked?

        update = @optimiser.update gradient, con.id

        con.weight += update
      end

      avg_batch_error
    end

    def self.run_single network, inputs, targets
      states = []
      inputs = [inputs] if inputs.flatten == inputs

      # run the data into the network. (feed forward)
      # all but last
      (inputs.size - 1).times do |timestep|
        network.evaluate inputs[timestep]
        states[timestep] = network.reset!
      end
      # last
      outputs = network.evaluate inputs.last
      states[inputs.size - 1] = network.reset!

      # calculate error
      error = mse targets, outputs

      # backward pass with unravelling for recurrent networks
      node_deltas = Hash.new{ |h, k| h[k] = Hash.new 0.to_d }
      gradients = Hash.new 0.to_d

      initial_timestep = inputs.size - 1
      neuron_stack = network.output_neurons.map{ |n| [n, initial_timestep] }

      while current = neuron_stack.shift
        neuron, timestep = current
        next if node_deltas[timestep].key? neuron.id

        from_here = bptt_connecting_to neuron, network, timestep
        neuron_stack.push *from_here

        # neuron delta is summation of neuron deltas deltas for the connections
        # from this neuron
        step_one =
          if neuron.output?
            output_index = network.output_neurons.index neuron
            mse_delta targets[output_index], outputs[output_index]
          else
            network.connections_from(neuron).reduce 0.to_d do |m, c|
              out_timestep = c.output_neuron.context? ? timestep + 1 : timestep
              output_node_delta = node_deltas[out_timestep][c.output_neuron.id]

              # connection delta is the output neuron delta multiplied by the
              # connection's weight
              connection_delta =
                if c.output_neuron.is_a? ProductNeuron
                  intermediate = states[out_timestep][:intermediates][c.output_neuron.id]
                  output_node_delta.mult intermediate.div(states[timestep][:values][c.input_neuron.id], RANN.d), RANN.d
                else
                  output_node_delta.mult c.weight, RANN.d
                end

              m + connection_delta
            end
          end

        node_delta =
          ACTIVATION_DERIVATIVES[neuron.activation_function]
            .call(states[timestep][:values][neuron.id])
            .mult(step_one, RANN.d)

        node_deltas[timestep][neuron.id] = node_delta

        in_timestep = neuron.context? ? timestep - 1 : timestep
        network.connections_to(neuron).each do |c|
          # connection gradient is the output neuron delta multipled by the
          # connection's input neuron value.
          gradient =
            if c.output_neuron.is_a? ProductNeuron
              intermediate = states[timestep][:intermediates][c.output_neuron.id]
              node_delta.mult intermediate.div(c.weight, RANN.d), RANN.d
            elsif c.input_neuron.context? && timestep == 0
              0.to_d
            else
              node_delta.mult states[in_timestep][:values][c.input_neuron.id], RANN.d
            end

          gradients[c.id] += gradient
        end
      end

      reset! network
      [gradients, error]
    end

    def save filepath = nil
      filepath ||= "rann_savepoint_#{DateTime.now.strftime('%Y-%m-%d-%H-%M-%S')}.yml"

      weights  = @network.params
      opt_vars = @optimiser.state

      File.open filepath, "w" do |f|
        f.write YAML.dump [weights, opt_vars]
      end
    end

    def restore filepath
      unless filepath
        filepath = Dir['*'].select{ |f| f =~ /rann_savepoint_.*/ }.sort.last

        unless filepath
          @network.init_normalised!
          puts "No savepoints found—initialised normalised weights"
          return
        end
      end

      weights, opt_vars = YAML.load_file(filepath)
      @network.impose(weights)
      @network.optimiser.load_state(opt_vars)
    end

    def self.reset! network
      network.reset!
      network.neurons.select(&:context?).each{ |n| n.value = 0.to_d }
    end

    def self.mse targets, outputs
      total_squared_error = 0.to_d

      targets.size.times do |i|
        total_squared_error += (targets[i] - outputs[i]).power(2, RANN.d).div 2, RANN.d
      end

      total_squared_error
    end

    def self.mse_delta target, actual
      actual - target
    end

    def self.bptt_connecting_to neuron, network, timestep
      # halt traversal if we're at a context and we're at the base timestep
      return [] if neuron.context? && timestep == 0

      network.connections_to(neuron).each.with_object [] do |c, a|
        # don't enqueue connections from inputs
        next if c.input_neuron.input?

        timestep -= timestep if neuron.context?
        a << [c.input_neuron, timestep]
      end
    end
  end
end
