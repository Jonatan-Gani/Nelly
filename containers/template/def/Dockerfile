# Use a slim Python image
FROM python:3.9-slim

# Define project name
ARG PROJECT_NAME=default_project
ENV PROJECT_NAME=$PROJECT_NAME

# Add a user for security purposes
RUN useradd -ms /bin/bash $PROJECT_NAME

# Create the app directory and set permissions
RUN mkdir -p /home/app && \
    chown -R $PROJECT_NAME:$PROJECT_NAME /home/app

# Copy the repository folder from the host to the container
COPY ./app /home/app

# Copy the cron file into the container as a root cron job
COPY ./def/cron /etc/cron.d/project-cron

# Set permissions for the cron file (required for cron in /etc/cron.d)
RUN chmod 0644 /etc/cron.d/project-cron

# Create the cron log file and set permissions
RUN touch /var/log/cron.log && chmod 0644 /var/log/cron.log

# Update pip and install Python dependencies
RUN pip install --upgrade pip && pip install -r /home/app/requirements.txt

# Start cron in the foreground as root
CMD ["cron", "-f"]
