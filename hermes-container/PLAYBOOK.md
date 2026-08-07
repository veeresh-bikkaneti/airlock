# Hermes Career Ops Playbook

A step-by-step guide to applying for jobs with Hermes agent and career-ops.

## Session 1: Initial Setup & CV Review

### Step 1: Start Hermes
```powershell
cd C:\path\to\airlock\hermes-container
.\run-hermes.ps1
```

### Step 2: Ask Hermes to review your profile
In the Hermes interactive session, try these prompts:

```
Review my career-ops profile and CV. What are the strongest points and what needs improvement?
```

```
Analyze my CV for ATS (Applicant Tracking System) compatibility. Suggest specific keyword improvements.
```

```
Check my resume against common job description requirements for software engineering roles. What gaps do you see?
```

### Step 3: Review Hermes' suggestions
Hermes will output suggestions to `/workspace/output/`. When you're done:
```powershell
.\stop-hermes.ps1
```
Review the extracted files, apply changes, commit.

---

## Session 2: Job Search & Portal Scanning

### Step 1: Start Hermes
```powershell
.\run-hermes.ps1
```

### Step 2: Scan for matching jobs
```
Read my career-ops portal configuration. Which portals have new jobs matching my profile? Run the scanner and analyze results.
```

```
I want to apply to software engineering roles at [COMPANY]. Review their job description and identify the top 5 skills I should highlight in my application.
```

### Step 3: Get job-specific advice
```
For this job description at portal X, write a tailored summary of why my experience matches. Focus on my 3 strongest matching points.
```

---

## Session 3: Cover Letter Generation

### Step 1: Start Hermes
```powershell
.\run-hermes.ps1
```

### Step 2: Generate cover letters
```
Generate a cover letter for the [ROLE] position at [COMPANY]. Use my CV and the job description as reference. Keep it authentic and avoid generic phrases.
```

```
Review this cover letter and make it more compelling. Add specific achievements from my CV that match the job requirements.
```

---

## Session 4: Interview Preparation

### Step 1: Start Hermes
```powershell
.\run-hermes.ps1
```

### Step 2: Prepare for interviews
```
Based on the job description for [ROLE] at [COMPANY], what technical questions should I prepare for? Generate a study guide.
```

```
Do a mock behavioral interview with me. Ask me 5 common behavioral questions and evaluate my responses against the job requirements.
```

```
Review my interview-prep directory and suggest improvements based on the latest industry trends for technical interviews.
```

---

## Session 5: Application Pipeline Management

### Step 1: Start Hermes
```powershell
.\run-hermes.ps1
```

### Step 2: Pipeline review
```
Review my application tracker. Which applications need follow-up? Generate a priority list based on application dates.
```

```
Check for status updates across my portals. Which applications have changed status since my last review?
```

```
Generate a weekly application progress report. Include: applications sent, responses received, interviews scheduled, offers pending.
```

---

## With NVIDIA NIM (Advanced)

When you need higher-quality output for important applications:

```powershell
.\run-hermes.ps1 -NimApiKey "nvapi-..."
```

Then inside Hermes, switch to a NIM model:
```
/model nvidia/llama-3.1-nemotron-ultra-253b-v1
```

NIM models are better for:
- Detailed CV analysis and rewriting
- Complex cover letter generation
- Technical interview preparation with nuanced knowledge
- Long-form content generation

---

## Tips for Best Results

1. **Be specific**: Tell Hermes the exact company, role, and what you need.
2. **Review everything**: Hermes reads your repo but can't know your personal preferences — review and edit before sending.
3. **One task per session**: Focus each Hermes session on one goal.
4. **Use local models for exploration**: Switch (`/model qwen2.5-coder:7b`) to smaller models for quick tasks.
5. **Use larger models for deliverables**: Switch (`/model devstral-small-2:24b`) for final output.
6. **Commit after each session**: Keep your repo clean — commit changes after each Hermes session.

## Commands Inside Hermes

| Command | What it does |
|---|---|
| `/model <name>` | Switch AI model mid-session |
| `/exit` | Quit Hermes |
| `/help` | Show all commands |
| `/tools` | List available tools |