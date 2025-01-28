# Use a slim Python image
FROM python:3.9-slim

# Define container name dynamically
ARG PROJECT_NAME
ENV PROJECT_NAME=$PROJECT_NAME

# Add a user for security purposes
RUN useradd -ms /bin/bash $PROJECT_NAME

# Create the apps directory and set permissions
RUN mkdir -p /home/apps && \
    chown -R $PROJECT_NAME:$PROJECT_NAME /home/apps

# Copy the entire apps folder into the container
COPY ./apps /home/apps

# Copy the cron file from the `def` folder into the container as a root cron job
COPY ./def/cron /etc/cron.d/project-cron

# Set permissions for the cron file (required for cron in /etc/cron.d)
RUN chmod 0644 /etc/cron.d/project-cron

# Create the cron log file and set permissions
RUN touch /var/log/cron.log && chmod 0644 /var/log/cron.log

# Ensure `/var/run` is writable by cron
RUN mkdir -p /var/run && chmod -R 0755 /var/run

# Install cron
RUN apt-get update && apt-get install -y cron

# Update pip (package installation will be added dynamically by the script)
RUN pip install --upgrade pip

RUN echo "Contents of /home/apps:" && ls -l /home/apps

RUN echo "Contents of /home:" && ls -l /home

# Placeholder for app requirements installation
# PLACEHOLDER: APP REQUIREMENTS INSTALLATION

# Set the working directory to /home
WORKDIR /home

# Start cron in the foreground as root
CMD ["cron", "-f"]
