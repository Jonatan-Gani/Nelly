# Use a slim Python image
FROM python:3.9-slim

# Define project name
ARG PROJECT_NAME=tamar_template
ENV PROJECT_NAME=$PROJECT_NAME

# Add a user for security purposes
RUN useradd -ms /bin/bash $PROJECT_NAME

# Create the app directory and set permissions
RUN mkdir -p /home/app && \
    chown -R $PROJECT_NAME:$PROJECT_NAME /home/app

# Copy the specific app folder into the container
COPY ./apps/$PROJECT_NAME /home/app

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

# Update pip and install Python dependencies
RUN pip install --upgrade pip && pip install -r /home/app/requirements.txt

# Set the working directory
WORKDIR /home/app

# Start cron in the foreground as root
CMD ["cron", "-f"]
