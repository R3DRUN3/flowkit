# Flowkit


Flowkit is a version-controlled toolkit for a self-hosted, local n8n automation stack, including Docker Compose, workflows, commands, and Bash scripts.  
It provides a single, reproducible home for building and managing n8n automations.    

Running n8n as a Docker container provides a portable and reproducible automation layer.  
SSH access to the host allows workflows to execute and orchestrate Dockerized tools without installing them inside n8n (custom docker image).  
This cleanly separates orchestration from tooling while keeping individual tools versioned, isolated, and replaceable.   
Read [this article](https://www.neteye-blog.com/blog/2026/01/27/architecting-a-portable-red-team-engine/) for a concrete use case.  



## Prerequisites  
- Linux host (tested on arch-linux and debian-based distros)  
- Docker
- Docker Compose
- sshd  


## Instructions  

### Fist deployment (from scratch):  


First of all, generate a self signed TLS cert for your n8n istance:  

```bash
mkdir certs && cd certs && openssl req -x509 -nodes -days 825 \
  -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout flowkit.key -out flowkit.crt \
  -subj "/CN=flowkit.local" \
  -addext "subjectAltName=DNS:flowkit.local,DNS:localhost,IP:<your-LAN-IP>"
```  

Now, from the repo root create the linux user `flowkit`, **this is the user that will run n8n SSH node on the host**:  
```bash
sudo bash scripts/create-flowkit-user.sh
```  


Now create the `.env` file by copying the content of `.env.example` and modify the env vars with your desired values.  

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

In this section, we will explore how to build an automation workflow based on an SSH node.  

SSH nodes can be particularly useful for executing commands directly on the host system.  
This enables workflows to perform tasks such as starting and managing Docker containers on the host, effectively turning n8n into an orchestration layer  
capable of integrating and controlling virtually any tool, service, or command-line operation required by the workflow.  

Create a simple workflow with a manual trigger and an SSH node:  
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






