PROJECT NAME
FluxDL

PLATFORM
Native Swift
SwiftUI
MVVM Architecture
Swift Concurrency (async/await)
Minimum iOS 18
Target Device: iPhone
Optimized for iPhone 15 Pro

BUILD REQUIREMENTS

This project will be built entirely on GitHub Actions.

The generated project MUST build successfully using GitHub macOS runners.

Never use APIs that require iOS SDK 26 or newer.

Use only APIs available in iOS SDK 18.

The project should build into an unsigned IPA suitable for sideloading using:
- Sideloadly
- AltStore
- SideStore
- LiveContainer

Avoid dependencies unless absolutely necessary.

Prefer Apple's native frameworks.

Performance is a top priority.

CPU usage:
Very Low

GPU usage:
Very Low

RAM usage:
Minimal

Battery usage:
Minimal

Never poll unnecessarily.

Never create unnecessary timers.

Use async event-driven architecture.

Use URLSession correctly.

Never block the main thread.

Architecture

MVVM

Dependency Injection

Protocol-based services

Repository pattern

No massive ViewControllers

No code duplication

Project structure should remain clean and scalable.

------------------------------------------------------

DESIGN

Create an Apple-quality interface.

Style:

iOS 26 inspired

implemented using iOS 18 SDK.

Use:

SwiftUI

NavigationStack

Glass style cards

Smooth animations

Native blur materials

Large rounded corners

Modern spacing

Beautiful typography

Native SF Symbols

Native Haptics

Adaptive Dark Mode

Adaptive Light Mode

Dynamic Type support

Accessibility support

Landscape support where appropriate.

------------------------------------------------------

BOTTOM TAB BAR

Only 4 tabs.

1.

Downloads

2.

Browser

3.

History

4.

Settings

No more tabs unless requested later.

------------------------------------------------------

SETTINGS PAGE

At the bottom place an About card.

App Name:
FluxDL

Developer:
RAKIB

Version

Build Number

GitHub placeholder

Licenses

Privacy

Terms placeholder

Check for Updates placeholder

------------------------------------------------------

IMPORTANT DEVELOPMENT RULE

DO NOT IMPLEMENT EVERYTHING AT ONCE.

Development must happen in phases.

After every phase:

Commit changes

Push to GitHub

Build unsigned IPA

Install on iPhone

Test

Fix bugs

Only then continue.

Never continue if previous phase is unstable.

------------------------------------------------------
PHASE 1
Foundation

Create project

Architecture

Theme

Navigation

Bottom tab bar

Settings page

Empty Downloads page

Empty Browser page

Empty History page

No download engine yet.

GitHub Build

Produce unsigned IPA

STOP.

------------------------------------------------------
PHASE 2

Basic Download Manager

Implement URLSession download engine.

Support:

HTTP

HTTPS

Download files

Pause

Resume

Cancel

Retry

Delete

Open in Files

Share

Progress bar

Remaining time

Speed

Downloaded size

File size

Status

Completed list

Persist downloads.

GitHub Build

STOP.

------------------------------------------------------
PHASE 3

Advanced Download Queue

Queue management

Priorities

Reorder downloads

Sequential mode

Parallel mode

Maximum concurrent downloads

Automatic retry

Duplicate detection

Storage management

Disk space calculation

Download statistics

GitHub Build

STOP.

------------------------------------------------------
PHASE 4

Background Downloads

Background URLSession

Resume after app restart

Resume after reboot

Background notifications

Correct handling of delegate callbacks

Automatic restoration

Battery efficient implementation

GitHub Build

STOP.

------------------------------------------------------
PHASE 5

Live Activities

Integrate ActivityKit.

Display:

File icon

Progress

Speed

ETA

Pause

Resume

Cancel

Support:

Lock Screen

Dynamic Island

Only update when needed.

Avoid excessive Live Activity updates.

Battery optimized.

GitHub Build

STOP.

------------------------------------------------------
PHASE 6

Dynamic Island

Expanded

Compact

Minimal

Smooth progress animation

Correct percentages

Remaining time

File name

Status

Battery efficient.

GitHub Build

STOP.

------------------------------------------------------
PHASE 7

Browser

Simple browser

Address bar

Paste URL

Auto detect downloadable files

Download button

Long press download

Context menu

Recent links

Bookmarks

History

GitHub Build

STOP.

------------------------------------------------------
PHASE 8

Clipboard Detection

Detect copied links.

Ask before downloading.

Smart recognition.

Recognize:

ZIP

RAR

MP4

MKV

IPA

PDF

Images

Audio

Documents

Do not constantly poll clipboard.

Use battery-friendly implementation.

GitHub Build

STOP.

------------------------------------------------------
PHASE 9

Advanced Download Features

Change download URL for an existing task.

Mirror switching.

Restart with new URL.

Rename file while downloading.

Checksum verification.

Auto categorize downloads.

Tag downloads.

Favorite downloads.

Search.

Filters.

Sorting.

Batch operations.

GitHub Build

STOP.

------------------------------------------------------
PHASE 10

Power User Features

Bandwidth limiter

Wi-Fi only

Cellular control

Low Power Mode awareness

Automatic pause on low battery

Automatic resume

Storage warnings

Import URLs

Export history

Download scheduler

Smart queue

Crash recovery

GitHub Build

STOP.

------------------------------------------------------
PHASE 11

Polish

Animations

Accessibility

Performance optimization

Memory optimization

Battery optimization

Profile using Instruments-compatible practices.

Eliminate leaks.

Lazy loading

Image caching

Thread optimization

GitHub Build

STOP.

------------------------------------------------------

GENERAL RULES

Always use:

Swift Concurrency

Actors where appropriate

Async/Await

Structured concurrency

Avoid unnecessary Combine.

Prefer Observation framework where applicable.

Avoid third-party libraries unless absolutely necessary.

Every feature should have:

Unit tests

Error handling

Logging

Recovery

No force unwraps.

No crashes.

No placeholder implementations.

No TODO comments.

Every feature must be production quality.

Maintain clean Git history.

After every completed phase:

Run tests

Fix warnings

Push to GitHub

Generate unsigned IPA

Stop and wait for testing feedback before continuing.