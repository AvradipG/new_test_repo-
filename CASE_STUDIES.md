# Project notes

[Return to the portfolio](README.md)

## From a waveform to a detection

A sonar signal chain brings together several ideas that are often taught separately: waveform design, propagation delays, correlation, noise and decision thresholds.

My [public DSP repository](https://github.com/AvradipG/sonar-dsp-projects) contains notebooks and scripts for exploring these ideas with synthetic signals. The collection includes linear chirps, coded waveforms, matched filtering, array simulations, time-frequency analysis and general filtering examples.

**What to inspect:** waveform definitions, sampling choices, the relationship between a reference signal and its correlation output, and the assumptions behind the array geometry. Start with the waveform notebooks, then the beamforming examples and the full pipeline notebook.

**Scope:** an educational simulation collection. Hardware execution, calibrated acoustic measurements, fractional-delay accuracy and operational detection performance require further work. Some folders contain exploratory notebooks or incomplete examples.

## Mathematical structure and numerical stability

My independent research work explores wave physics through complex matrix calculations and geometric descriptions of polarization. The code includes numerical experiments designed to make sensitivity and representation choices visible.

The skill I want this work to demonstrate is the ability to move between a mathematical definition, its numerical implementation and the interpretation of the result. A stable-looking figure is not enough. Normalization choices, phase conventions and behavior near degeneracy matter.

**Scope:** private independent research. Manuscript text, unpublished figures and detailed results are not published in this portfolio.

## Making research easier to review

I have also worked on an independent manuscript interface with mathematical-content navigation, annotation tools and versioned source. The aim is practical: keep the source recoverable and make equations, figures and comments easier to follow while a paper evolves.

**Scope:** a saved software prototype. Browser/stylus behavior and deployment state need separate checks. Its source and manuscript material remain private.

## Reading this portfolio

The public examples are evidence of the topics I work through and the tools I use. They are not a claim that every example is complete, that a numerical benchmark validates a physical model, or that every application is production software.

Workplace source, internal processes, client information and employer-specific project descriptions are intentionally absent. The personal research backup is separate from the public demonstrations.
