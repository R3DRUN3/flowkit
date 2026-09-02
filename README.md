# Flowkit


<img src="./media/logo.png" alt="logo" style="width:350px; height:310px;"/>


Flowkit is an environment for managing a self-hosted n8n automation stack.  
It provides a single, reproducible home for building and managing n8n orchestrations that can also leverage docker containers.    

Running n8n as a Docker container provides a portable and reproducible automation layer.  
SSH access to the host allows workflows to execute and orchestrate Dockerized tools without installing them inside n8n (custom docker image).  
Versioning workflows allow for a GitOps approach.    
This cleanly separates orchestration from tooling while keeping individual tools versioned, isolated, and replaceable.  

Read [this article](https://www.neteye-blog.com/blog/2026/01/27/architecting-a-portable-red-team-engine/) for a concrete use case.  


## Table of Contents

- [Flowkit](#flowkit)
  - [Table of Contents](#table-of-contents)
  - [Prerequisites](#prerequisites)
  - [Instructions](#instructions)
    - [First deployment](#first-deployment)
      - [TLS cert generation](#tls-cert-generation)
      - [Create SSH-enabled user](#create-ssh-enabled-user)
      - [Configure env vars](#configure-env-vars)
      - [Deploy](#deploy)
    - [Workflows](#workflows)
      - [Create your fist docker-based workflow](#create-your-fist-docker-based-workflow)
      - [Manage workflows](#manage-workflows)


## Prerequisites  
- Linux host (tested on arch-linux and debian-based distros)  
- Docker
- Docker Compose
- sshd  
- Python3

## Instructions  

### First deployment  

#### TLS cert generation  


First of all, generate a self signed TLS cert for your n8n istance:  

```bash
mkdir certs && cd certs && openssl req -x509 -nodes -days 825 \
  -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout flowkit.key -out flowkit.crt \
  -subj "/CN=flowkit.local" \
  -addext "subjectAltName=DNS:flowkit.local,DNS:localhost,IP:<your-LAN-IP>"
```  

> [!TIP]
> **Why self-signed TLS?**  
> Flowkit is structured to keep n8n private and off the public Internet, so a publicly trusted Let's Encrypt certificate isn't necessary.  
> If remote access is needed, I prefer [Tailscale](https://tailscale.com/) and its HTTPS certificates instead of exposing n8n publicly.

#### Create SSH-enabled user  

From the repo root create the linux user `flowkit`, **this is the user that will run n8n SSH node on the host**:  
```bash
sudo bash scripts/create-flowkit-user.sh
```  

#### Configure env vars  

Create the `.env` file by copying the content of `.env.example` and modify the env vars with your desired values.  

#### Deploy  

Now you are ready for the deploy, run:  
```bash
bash scripts/deploy.sh
```  
If this is the first deployment it will also pull all the required docker images.  
Once the deployment has completed and n8n is ready, open your browser at `https://localhost:6789` and configure n8n user for UI authentication, for example:  

![ui-user](./media/ui_user_registration.png)  

Keep track of email and password as you will need them later to login again.  
Now try to stop the deployment and restart it:  
```bash
bash scripts/stop.sh
bash scripts/deploy.sh
```  

You should now be able to login with the user you previously created and you'll have a working n8n istance deployed  🥳  


### Workflows  

#### Create your fist docker-based workflow  

In this section, we will explore how to build an automation workflow based on an SSH node.  

SSH nodes can be particularly useful for executing commands directly on the host system.  
This enables workflows to perform tasks such as starting and managing Docker containers on the host, effectively turning n8n into an orchestration layer  
capable of integrating and controlling virtually any tool, service, or command-line operation required by the workflow.  

Create a simple workflow with a manual trigger and an SSH node, call it `demo-ssh-workflow`:    
![w1](./media/ssh_workflow_1.png)  

Click on the SSH node and configure it, set the following as the command:  
```bash
docker run --rm curlimages/curl:8.22.0 -s https://httpbin.org/json
```  
![w2](./media/ssh_workflow_2.png)  


Now click on `Connect to SSH Password` and configure authentication with the `flowkit` ssh user you created at the beginning of the deployment:  
![w3](./media/ssh_workflow_3.png)  

Add a code node to your workflow with this javascript inside:  
```javascript
return [
  {
    json: JSON.parse($json.stdout)
  }
];
```

Now run the workflow ad observe the output:  
![w4](./media/ssh_workflow_4.png)  
Congrats, you sucesfully runned your fist docker workflow! 💪  

#### Manage workflows






