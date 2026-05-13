# 🚚 VRPRDL Solver (Julia + Column Generation)

## 📌 Overview

This project implements solution approaches for the **Vehicle Routing Problem with Roaming Delivery Locations (VRPRDL)** using:

- Julia
- JuMP + CPLEX
- Column Generation (CG)
- Batch execution via Bash

The project evolves from classical VRP approaches to a decomposition-based method inspired by the literature.

---

## 📚 Main Reference

Ozbaygin, G., et al. (2017)

- Solves VRPRDL using:
  - Set Partitioning
  - Column Generation
  - Branch-and-Price
  - RCSP (Resource Constrained Shortest Path)

---

## 🧩 Problem Description

In VRPRDL:

- Each **customer has multiple candidate locations**
- Each location has:
  - coordinates
  - time window
- The solver must:
  - choose **exactly one location per customer**
  - respect:
    - vehicle capacity
    - time windows
    - route duration

---

## 🔥 Key Difference from VRP

| Feature | VRP | VRPRDL |
|--------|-----|--------|
| Nodes per customer | 1 | Multiple |
| Location choice | No | Yes |
| Complexity | Moderate | High |

---

## 🧠 Mathematical Formulation (High-Level)

### Master Problem

Minimize:

    sum(c_r * λ_r)
    
Subject to:

    sum(a_cr * λ_r) = 1   for all customers c

    λ_r >= 0

Where:
- λ_r = decision variable for route r
- a_cr = 1 if route r serves customer c

---

## ⚙️ Pricing Problem

Goal: generate routes with negative reduced cost

Reduced cost:

    c_r - sum(π_c)

Where:
- π_c = dual variable of customer constraint

---

## 📂 Project Structure

instancias_turco/
│
├── VRPRDL-triangle/
│   ├── json_convertidos/
│   ├── logs_cg_heuristic/
│
├── vrprdl_cg_heuristic.jl
├── rodar_vrprdl_cg_batch.sh

---

## 🔁 Pipeline

TXT (paper instances)
    ↓
Parser → JSON
    ↓
Column Generation (Julia)
    ↓
Logs

---

## 🧪 Implemented Stages

### 1. Parsing

- Converts original instance format to JSON
- Extracts:
  - customers
  - candidate locations
  - time windows
  - travel times

---

### 2. MIP Baseline

File:

    resolver_vrprdl_mip.jl

- Direct formulation
- Used for validation

---

### 3. Column Generation

File:

    vrprdl_cg_heuristic.jl

Components:

- Restricted Master Problem (RMP)
- Initial columns
- Heuristic pricing
- Iterative CG loop

---

## 🚀 Running the Project

### Single instance

    julia vrprdl_cg_heuristic.jl instance_0-triangle.json

---

### Batch execution

    dos2unix rodar_vrprdl_cg_batch.sh
    chmod +x rodar_vrprdl_cg_batch.sh
    ./rodar_vrprdl_cg_batch.sh

---

## 📂 Outputs

Logs stored in:

    VRPRDL-triangle/logs_cg_heuristic/

Each log contains:

- CG iterations
- Objective values
- Generated columns
- Final solution

---

## ⚠️ Current Limitations

- Pricing is heuristic
- No exact RCSP implementation
- No Branch-and-Price yet

---

## 🧭 Roadmap

### Short term
- Improve pricing (beam search, multi-start)

### Medium term
- Implement RCSP

### Long term
- Full Branch-and-Price

---

## 💡 Key Insight

VRPRDL combines:

    routing + combinatorial location choice

This requires decomposition techniques like Column Generation.

---

## 🛠️ Stack

- Julia
- JuMP
- CPLEX
- Bash
- WSL

---

## 🏁 Status

✔ Parser complete  
✔ CG working  
✔ Batch execution ready  

🔄 Ongoing improvements toward full academic solution
