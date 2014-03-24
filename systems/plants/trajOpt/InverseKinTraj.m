classdef InverseKinTraj < NonlinearProgramWConstraint
% solve IK
%   min_q sum_i
%   qdd(:,i)'*Qa*qdd(:,i)+qd(:,i)'*Qv*qd(:,i)+(q(:,i)-q_nom(:,i))'*Q*(q(:,i)-q_nom(:,i))]+additional_cost1+additional_cost2+...
%   subject to
%          constraint1 at t_samples(i)
%          constraint2 at t_samples(i)
%          ...
%          constraint(k)   at [t_samples(2) t_samples(3) ... t_samples(nT)]
%          constraint(k+1) at [t_samples(2) t_samples(3) ... t_samples(nT)]
%   ....
%
% using q_seed_traj as the initial guess. q(1) would be fixed to
% q_seed_traj.eval(t(1))
% @param robot    -- A RigidBodyManipulator or a TimeSteppingRigidBodyManipulator
% @param t_knot   -- A 1 x nT double vector. The t_knot(i) is the time of the i'th knot
% point
% @param Q        -- The matrix that penalizes the posture error
% @param q_nom_traj    -- The nominal posture trajectory
% @param Qv       -- The matrix that penalizes the velocity
% @param Qa       -- The matrix that penalizes the acceleration
% @param rgc      -- A cell of RigidBodyConstraint
% @param x_name   -- A string cell, x_name{i} is the name of the i'th decision variable
%
  properties(SetAccess = protected)
    robot
    t_knot
    Q
    q_nom_traj
    Qv
    Qa
    rgc
    x_name
  end
  
  properties(Access = protected)
    nq
    nT
    q_nom   % a nq x nT matrix. q_nom = q_nom_traj.eval(t)
    q_idx   % a nq x nT matrix. q(:,i) = x(q_idx(:,i))
    qd0_idx  % a nq x 1 matrix. qdot0 = x(qd0_idx);
    qdf_idx  % a nq x 1 matrix. qdotf = x(qdf_idx);
    qsc_weight_idx    % a cell of vectors.x(qsc_weight_idx{i}) are the weights of the QuasiStaticConstraint at time t(i)
    cpe   % A CubicPostureError object.
    t_kinsol   % A 1 x nT boolean array. t_kinsol(i) is true if doKinematics should be called at time t_knot(i)
    cost_kinsol_idx % A cell. cost_kinsol_idx{i} is the indices of kinsol used for evaluating cost{i}
    nlcon_kinsol_idx % A cell. nlcon_kinsol_idx{i} is the indices of kinsol used for evaluating nlcon{i}
  end
  
  methods
    function obj = InverseKinTraj(robot,t,q_nom_traj,varargin)
      % obj =
      % InverseKinTraj(robot,t,q_nom_traj,RigidBodyConstraint1,RigidBodyConstraint2,...,RigidBodyConstraintN)
      % @param robot    -- A RigidBodyManipulator or a TimeSteppingRigidBodyManipulator
      % @param t   -- A 1 x nT double vector. t(i) is the time of the i'th knot
      % point
      % @param q_nom_traj    -- The nominal posture trajectory
      % @param RigidBodyConstraint_i    % A RigidBodyConstraint object
      if(~isa(robot,'RigidBodyManipulator') && ~isa(robot,'TimeSteppingRigidBodyManipulator'))
        error('Drake:InverseKinTraj:robot should be a RigidBodyManipulator or a TimeSteppingRigidBodyManipulator');
      end
      t = unique(t(:)');
      obj = obj@NonlinearProgramWConstraint(robot.getNumDOF*(length(t)+2));
      obj.robot = robot;
      obj.nq = obj.robot.getNumDOF();
      obj.nT = length(t);
      obj.t_knot = t;
      if(~isa(q_nom_traj,'Trajectory'))
        error('Drake:InverseKinTraj:q_nom_traj should be a trajectory');
      end
      obj.q_nom_traj = q_nom_traj;
      obj.q_nom = obj.q_nom_traj.eval(obj.t_knot);
      obj.q_idx = reshape((1:obj.nq*obj.nT),obj.nq,obj.nT);
      obj.qd0_idx = obj.nq*obj.nT+(1:obj.nq)';
      obj.qdf_idx = obj.nq*(obj.nT+1)+(1:obj.nq)';
      obj.qsc_weight_idx = cell(1,obj.nT);
      num_rbcnstr = nargin-3;
      obj.t_kinsol = false(1,obj.nT);
      obj.cost_kinsol_idx = {};
      obj.nlcon_kinsol_idx = {};
      obj.x_name = cell(obj.nq*obj.nT,1);
      for i = 1:obj.nT
        for j = 1:obj.nq
          obj.x_name{i} = sprintf('q%d[%d]',j,i);
        end
      end
      for i = 1:num_rbcnstr
        if(~isa(varargin{i},'RigidBodyConstraint'))
          error('Drake:InverseKinTraj:the input should be a RigidBodyConstraint');
        end
        if(isa(varargin{i},'SingleTimeKinematicConstraint'))
          for j = 1:obj.nT
            if(varargin{i}.isTimeValid(obj.t_knot(j)))
              cnstr = varargin{i}.generateConstraint(obj.t_knot(j));
              obj = obj.addNonlinearConstraint(cnstr{1},obj.q_idx(:,j));
              obj.nlcon_kinsol_idx = [obj.nlcon_kinsol_idx,{j}];
              obj.t_kinsol(j) = true;
            end
          end
        elseif(isa(varargin{i},'PostureConstraint'))
          for j = 1:obj.nT
            if(varargin{i}.isTimeValid(obj.t_knot(j)))
              cnstr = varargin{i}.generateConstraint(obj.t_knot(j));
              obj = obj.addBoundingBoxConstraint(cnstr{1},obj.q_idx(:,j));
            end
          end
        elseif(isa(varargin{i},'SingleTimeLinearPostureConstraint'))
          for j = 1:obj.nT
            if(varargin{i}.isTimeValid(obj.t_knot(j)))
              cnstr = varargin{i}.generateConstraint(obj.t_knot(j));
              obj = obj.addLinearConstraint(cnstr{1},obj.q_idx(:,j));
            end
          end
        elseif(isa(varargin{i},'MultipleTimeKinematicConstraint'))
          valid_t_flag = varargin{i}.isTimeValid(obj.t_knot);
          cnstr = varargin{i}.generateConstraint(obj.t_knot(valid_t_flag));
          obj = obj.addNonlinearConstraint(cnstr{1},reshape(obj.q_idx(:,valid_t_flag),[],1));
          t_idx = (1:obj.nT);
          obj.nlcon_kinsol_idx = [obj.nlcon_kinsol_idx,{t_idx(valid_t_flag)}];
          obj.t_kinsol(valid_t_flag) = true;
        elseif(isa(varargin{i},'MultipleTimeLinearPostureConstraint'))
          
        end
      end
      obj.Q = eye(obj.nq);
      obj.Qv = 0*eye(obj.nq);
      obj.Qa = 1e-3*eye(obj.nq);
      obj = obj.setCubicPostureError(obj.Q,obj.Qv,obj.Qa);
      obj = obj.setSolverOptions('snopt','majoroptimalitytolerance',1e-4);
      obj = obj.setSolverOptions('snopt','superbasicslimit',2000);
      obj = obj.setSolverOptions('snopt','majorfeasibilitytolerance',1e-6);
      obj = obj.setSolverOptions('snopt','iterationslimit',10000);
      obj = obj.setSolverOptions('snopt','majoriterationslimit',200);
    end
    
    function obj = setCubicPostureError(obj,Q,Qv,Qa)
      % set the cost sum_i qdd(:,i)'*Qa*qdd(:,i)+qd(:,i)'*Qv*qd(:,i)+(q(:,i)-q_nom(:,i))'*Q*(q(:,i)-q_nom(:,i))]
      obj.Q = (Q+Q')/2;
      obj.Qv = (Qv+Qv')/2;
      obj.Qa = (Qa+Qa')/2;
      obj.cpe = CubicPostureError(obj.t_knot,obj.Q,obj.q_nom,obj.Qv,obj.Qa);
      if(isempty(obj.cost))
        obj = obj.addCost(obj.cpe,[obj.q_idx(:);obj.qd0_idx;obj.qdf_idx]);
        obj.cost_kinsol_idx = {[]};
      else
        obj = obj.replaceCost(obj.cpe,1,[obj.q_idx(:);obj.qd0_idx;obj.qdf_idx]);
        obj.cost_kinsol_idx{1} = [];
      end
    end
    
    function [f,G] = objectiveAndNonlinearConstraints(obj,x)
      kinsol_cell = cell(1,obj.nT);
      for i = 1:obj.nT
        if obj.t_kinsol(i)
          kinsol_cell{i} = obj.robot.doKinematics(x(obj.q_idx(:,i)),false,false);
        end
      end
      f = zeros(1+obj.num_nlcon,1);
      G = zeros(1+obj.num_nlcon,obj.num_vars);
      for i = 1:length(obj.cost)
        if(~isempty(obj.cost_kinsol_idx{i}))
          [fi,dfi] = obj.cost{i}.eval(kinsol_cell(obj.cost_kinsol_idx));
        else
          [fi,dfi] = obj.cost{i}.eval(x(obj.cost_xind_cell{i}));
        end
        f(1) = f(1)+fi;
        G(1,obj.cost_xind_cell{i}) = G(1,obj.cost_xind_cell{i})+dfi;
      end
      f_count = 1;
      for i = 1:length(obj.nlcon)
        if(~isempty(obj.nlcon_kinsol_idx{i}))
          if(length(obj.nlcon_kinsol_idx{i}) == 1)
            [f(f_count+(1:obj.nlcon{i}.num_cnstr)),G(f_count+(1:obj.nlcon{i}.num_cnstr),obj.nlcon_xind{i})] = ...
              obj.nlcon{i}.eval(kinsol_cell{obj.nlcon_kinsol_idx{i}});
          else
            [f(f_count+(1:obj.nlcon{i}.num_cnstr)),G(f_count+(1:obj.nlcon{i}.num_cnstr),obj.nlcon_xind{i})] = ...
              obj.nlcon{i}.eval(kinsol_cell(obj.nlcon_kinsol_idx{i}));
          end
        else
          [f(f_count+(1:obj.nlcon{i}.num_cnstr)),G(f_count+(1:obj.nlcon{i}.num_cnstr),obj.nlcon_xind{i})] = ...
            obj.nlcon{i}.eval(x(obj.nlcon_xind{i}));
        end
        f(f_count+obj.nlcon{i}.ceq_idx) = f(f_count+obj.nlcon{i}.ceq_idx)-obj.nlcon{i}.ub(obj.nlcon{i}.ceq_idx);
        f_count = f_count+obj.nlcon{i}.num_cnstr;
      end
      f = [f(1);f(1+obj.nlcon_ineq_idx);f(1+obj.nlcon_eq_idx)];
      G = [G(1,:);G(1+obj.nlcon_ineq_idx,:);G(1+obj.nlcon_eq_idx,:)];
    end
    
    
  end
end