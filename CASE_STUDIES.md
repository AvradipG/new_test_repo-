# Digital Rock Simulation: Scientific Focus

[Return to the portfolio](README.md)

## From a digital rock to a flow model

A three-dimensional rock image provides a geometric starting point for a simulation. The modeled pore space, solid boundaries, physical scale and computational domain all affect the problem being solved.

My focus is connecting that structure to a fluid-flow calculation and interpreting what the simulated response says about transport through the rock.

Questions include whether the resolved geometry captures the relevant pathways, how the selected domain influences the result, and how image resolution or segmentation changes the modeled pore space.

## Connectivity and transport

Porosity describes the amount of pore space. Connectivity describes relationships between pores and possible pathways across a domain. Fluid-flow simulations examine transport through that structure under specified physical conditions.

These quantities answer different questions. A connectivity percentage alone does not establish permeability. The flow solution, its boundary conditions and its convergence determine whether a transport estimate is meaningful.

## Interpreting a fluid-flow simulation

I am interested in how pore geometry affects flow distribution, preferred pathways and directional transport behavior.

A useful interpretation connects the numerical fields to the geometry and the imposed conditions. It also considers whether the modeled volume and spatial resolution are suitable for the physical question.

## Numerical reliability

The checks I care about include:

- consistent units, voxel dimensions and coordinate conventions;
- explicit inlet, outlet and solid-boundary conditions;
- mass conservation and solver convergence;
- sensitivity to resolution, segmentation and domain size;
- reproducibility of the calculation and its processing history.

These are criteria for assessing a simulation. This portfolio does not claim that every development project has already passed every validation step.

## Scientific computing

Python and C++ support numerical calculations, data processing and scientific tools. Three-dimensional visualization helps inspect geometry and simulation output. Clear metadata and versioned source make a calculation easier to review and recover.

My professional focus is digital rock simulation and pore-scale fluid flow. This page contains general scientific descriptions only. Company code, client information, internal processes and confidential results are excluded.
